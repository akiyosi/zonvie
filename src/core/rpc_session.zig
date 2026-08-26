// rpc_session.zig — RPC dispatch, event loop, and session management.
// Extracted from nvim_core.zig. Free functions take *Core as first parameter.

const std = @import("std");
const builtin = @import("builtin");
const clock = @import("clock.zig");
const c_api = @import("c_api.zig");
const grid_mod = @import("grid.zig");
const highlight = @import("highlight.zig");
const mp = @import("msgpack.zig");
const rpc = @import("rpc_encode.zig");
const redraw = @import("redraw_handler.zig");
const config = @import("config.zig");
const log_mod = @import("log.zig");
const Logger = log_mod.Logger;
const flush = @import("flush.zig");
const nvim_core = @import("nvim_core.zig");
const Core = nvim_core.Core;
const Callbacks = nvim_core.Callbacks;
const rpc_transport = @import("rpc_transport.zig");

pub const PipeReader = struct {
    file: rpc_transport.Stream,
    buf: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(self: *PipeReader) !void {
        if (self.start < self.end) return;
        const n = try self.file.read(&self.buf);
        self.start = 0;
        self.end = n;
    }

    pub fn read(self: *PipeReader, dest: []u8) !usize {
        if (dest.len == 0) return 0;

        var out_i: usize = 0;
        while (out_i < dest.len) {
            try self.fill();
            if (self.end == 0) break; // EOF

            const avail = self.end - self.start;
            const take = @min(avail, dest.len - out_i);
            std.mem.copyForwards(u8, dest[out_i .. out_i + take], self.buf[self.start .. self.start + take]);
            self.start += take;
            out_i += take;

            if (take == 0) break;
        }
        return out_i;
    }

    pub fn readByte(self: *PipeReader) !u8 {
        var one: [1]u8 = undefined;
        const n = try self.read(one[0..]);
        if (n != 1) return error.EndOfStream;
        return one[0];
    }

    pub fn readNoEof(self: *PipeReader, dest: []u8) !void {
        var off: usize = 0;
        while (off < dest.len) {
            const n = try self.read(dest[off..]);
            if (n == 0) return error.EndOfStream;
            off += n;
        }
    }
};

/// Contiguous buffered reader that hands the MessagePack decoder zero-copy
/// slices of the pending frame.
///
/// Invariants:
///   - `buf[pos..end]` is the unconsumed window visible to the decoder
///   - `buf[end..buf.len]` is available for future reads from the pipe
///   - slices returned by `view()` are only valid until the next `fill()`
///     or `consume*()` call, since those may move/reallocate the backing
///     store.
///
/// The buffer grows on demand up to `max_capacity` when a single frame
/// exceeds the current capacity with no consumable tail to compact.
pub const FrameReader = struct {
    file: rpc_transport.Stream,
    alloc: std.mem.Allocator,
    buf: []u8,
    pos: usize = 0,
    end: usize = 0,

    pub const initial_capacity: usize = 64 * 1024;
    pub const max_capacity: usize = 64 * 1024 * 1024;

    pub fn init(alloc: std.mem.Allocator, file: rpc_transport.Stream) !FrameReader {
        const buf = try alloc.alloc(u8, initial_capacity);
        return .{ .file = file, .alloc = alloc, .buf = buf };
    }

    pub fn deinit(self: *FrameReader) void {
        self.alloc.free(self.buf);
        self.buf = &.{};
        self.pos = 0;
        self.end = 0;
    }

    /// Unconsumed window. Valid until the next `fill()` or `consume*()`.
    pub fn view(self: *const FrameReader) []const u8 {
        return self.buf[self.pos..self.end];
    }

    /// Mark `n` bytes of the current view as consumed.
    pub fn consume(self: *FrameReader, n: usize) void {
        std.debug.assert(self.pos + n <= self.end);
        self.pos += n;
        if (self.pos == self.end) {
            self.pos = 0;
            self.end = 0;
        }
    }

    /// Commit an advance position expressed as the remaining (uneaten) slice
    /// of the view, as a decoder that consumes from the front would leave it.
    /// `remaining` must be a sub-slice of `view()`.
    pub fn consumeTo(self: *FrameReader, remaining: []const u8) void {
        const base_addr = @intFromPtr(self.buf.ptr) + self.pos;
        const rem_addr = @intFromPtr(remaining.ptr);
        std.debug.assert(rem_addr >= base_addr);
        std.debug.assert(rem_addr <= base_addr + (self.end - self.pos));
        const consumed_n = rem_addr - base_addr;
        self.consume(consumed_n);
    }

    /// Pull more bytes from the pipe into `buf[end..]`. Compacts or grows
    /// the buffer first if the tail is exhausted. Returns 0 on EOF.
    ///
    /// The buffer is capped so an incomplete or malicious frame cannot grow
    /// process memory without bound. Normal frames are consumed before the
    /// next fill, so the cap applies to one outstanding wire object.
    pub fn fill(self: *FrameReader) !usize {
        if (self.end == self.buf.len) {
            if (self.pos > 0) {
                const live = self.end - self.pos;
                std.mem.copyForwards(u8, self.buf[0..live], self.buf[self.pos..self.end]);
                self.pos = 0;
                self.end = live;
            } else {
                if (self.buf.len >= max_capacity) return error.FrameTooLarge;
                const new_cap = @min(self.buf.len * 2, max_capacity);
                self.buf = try self.alloc.realloc(self.buf, new_cap);
            }
        }
        const n = try self.file.read(self.buf[self.end..]);
        self.end += n;
        return n;
    }
};

comptime {
    // A maximum-sized blob still needs MessagePack and RPC container bytes in
    // the outstanding wire frame.
    std.debug.assert((mp.DecodeLimits{}).max_blob_bytes < FrameReader.max_capacity);
}

/// Reader adapter that feeds `mp.decode` from a `[]const u8` view and tracks
/// how many bytes were successfully consumed. Used as the bridge between
/// `FrameReader.view()` and the current reader-based `mp.decode` during the
/// streaming migration: after a successful decode, the caller commits via
/// `FrameReader.consume(sr.i)`; on `error.EndOfStream` the caller refills
/// and retries from the same starting offset.
pub const FrameSliceReader = struct {
    data: []const u8,
    i: usize = 0,

    pub fn readByte(self: *FrameSliceReader) !u8 {
        if (self.i >= self.data.len) return error.EndOfStream;
        const b = self.data[self.i];
        self.i += 1;
        return b;
    }

    pub fn readNoEof(self: *FrameSliceReader, dest: []u8) !void {
        if (self.i + dest.len > self.data.len) return error.EndOfStream;
        @memcpy(dest, self.data[self.i .. self.i + dest.len]);
        self.i += dest.len;
    }
};

pub const CwdOwner = struct {
    open: bool = false,
    dir: std.Io.Dir = undefined,

    pub fn close(self: *CwdOwner) void {
        if (self.open) {
            self.dir.close(clock.io());
            self.open = false;
        }
    }

    pub fn openPreferred(self: *CwdOwner, alloc: std.mem.Allocator, log: *Logger) void {
        self.close();

        // Prefer $HOME when present.
        const home = envVarOwned(alloc, "HOME") catch null;
        defer if (home) |s| alloc.free(s);

        if (home) |home_path| {
            if (std.Io.Dir.openDirAbsolute(clock.io(), home_path, .{})) |d| {
                self.dir = d;
                self.open = true;
                log.write("child cwd set to HOME: {s}\n", .{home_path});
                return;
            } else |e| {
                log.write("openDirAbsolute(HOME) failed: {any} (HOME={s})\n", .{ e, home_path });
            }
        } else {
            log.write("HOME is not set; leaving child cwd as default\n", .{});
        }
    }

    /// Produce the `Child.Cwd` value to feed `std.process.spawn`'s
    /// `SpawnOptions.cwd`. Returns `.inherit` when no preferred dir was
    /// opened, preserving the prior default-cwd behavior.
    pub fn childCwd(self: *CwdOwner) std.process.Child.Cwd {
        if (!self.open) return .inherit;
        return .{ .dir = self.dir };
    }
};

/// Owned-copy environment variable lookup. Replaces 0.15's
/// `std.process.getEnvVarOwned`, which is removed in 0.16. Reads the
/// process environment via libc `getenv` and returns a heap copy the
/// caller owns, mirroring the old null/owned-free semantics.
fn envVarOwned(alloc: std.mem.Allocator, name: [*:0]const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const val = std.c.getenv(name) orelse return error.EnvironmentVariableNotFound;
    return alloc.dupe(u8, std.mem.span(val));
}

/// POSIX child-wait service created before a spawned session is admitted.
/// A preserved child is transferred to this already-running thread during
/// cleanup, so waitpid progress neither allocates nor depends on stderr EOF.
pub const ChildReaper = struct {
    alloc: std.mem.Allocator,
    mu: std.Io.Mutex,
    decision_ready: std.Io.Condition,
    decided: bool,
    child: ?std.process.Child,
    refcount: std.atomic.Value(u32),
    reaped: std.atomic.Value(bool),

    pub fn release(self: *ChildReaper) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) self.alloc.destroy(self);
    }

    pub fn run(self: *ChildReaper) void {
        defer self.release();

        self.mu.lockUncancelable(clock.io());
        while (!self.decided) {
            self.decision_ready.waitUncancelable(clock.io(), &self.mu);
        }
        var child = self.child;
        self.child = null;
        self.mu.unlock(clock.io());

        if (child) |*owned| {
            _ = owned.wait(clock.io()) catch return;
            self.reaped.store(true, .release);
        }
    }

    fn adopt(self: *ChildReaper, child: std.process.Child) bool {
        self.mu.lockUncancelable(clock.io());
        defer self.mu.unlock(clock.io());
        if (self.decided) return false;
        self.child = child;
        self.decided = true;
        self.decision_ready.signal(clock.io());
        return true;
    }

    pub fn finishWithoutChild(self: *ChildReaper) void {
        self.mu.lockUncancelable(clock.io());
        defer self.mu.unlock(clock.io());
        if (self.decided) return;
        self.decided = true;
        self.decision_ready.signal(clock.io());
    }
};

/// Build a child-process environment map from the LIVE libc `environ` at call
/// time (POSIX only). Returns null on Windows and on allocation failure.
///
/// Why this exists: `std.process.spawn` uses the shared Io's environ, which is
/// a snapshot taken once when the Io is first initialized (see clock.zig). The
/// frontend sets variables like SSH_ASKPASS / DISPLAY via libc `setenv` at
/// connection time — long after Io init — and `setenv` typically reallocates
/// the `environ` array, so the snapshot never sees them and the spawned SSH
/// child loses its askpass hook (silent SSH auth failure). Passing a freshly
/// scanned environ_map at spawn restores the pre-0.16 `std.process.Child`
/// behavior of inheriting the live environment. Windows is unaffected: its Io
/// environ is a GlobalBlock that reads the live PEB.
fn liveEnvironMap(alloc: std.mem.Allocator) ?std.process.Environ.Map {
    if (builtin.os.tag == .windows) return null;
    const c_env = std.c.environ;
    var n: usize = 0;
    while (c_env[n] != null) : (n += 1) {}
    const block: std.process.Environ.PosixBlock = .{ .slice = @ptrCast(c_env[0..n :null]) };
    var map = std.process.Environ.Map.init(alloc);
    map.putPosixBlock(block.view()) catch {
        map.deinit();
        return null;
    };
    return map;
}

/// Heap-allocated stderr pump state, refcount-managed so Core and the
/// pump thread can release their references independently. This
/// matters for the `:connect` orphan path: the old nvim keeps its
/// stderr writer open after we hot-swap, our blocked POSIX read does
/// not wake when we close our copy of the fd from cleanupSession, so
/// the pump must run detached until the orphan eventually closes
/// stderr — which can outlive Core itself if zonvie quits before the
/// orphan does. At the same time, the pump can exit at ANY moment
/// (orphan dies before cleanupSession reaches detachFromCore), so a
/// raw self-destroy in run()'s defer would race Core's pointer use.
///
/// Lifetime contract:
///   - At spawn, refcount = 2: one ref for Core (held via
///     Core.stderr_pump), one ref for the pump thread.
///   - Each holder calls release() exactly once when done. The last
///     release closes f and frees the struct.
///   - Core MUST keep its ref live across any access to the struct
///     (detachFromCore, etc.) and call release() afterwards. Orphan
///     path: detachFromCore + release; non-orphan: thread.join (which
///     drops the thread's ref) then Core's release.
///
/// Core access begins under `mu` and increments `active_core_users`, but
/// frontend callbacks run without the mutex held. cleanupSession's orphan
/// path calls detachFromCore(), which nulls the back-pointer and waits for
/// active users before letting Core go away. The mutex/condition being inside
/// the heap struct (not Core) is what makes this safe for detached pumps.
///
/// `alloc` MUST outlive every release(). Callers pass
/// std.heap.c_allocator (process-lifetime) instead of CoreBox's GPA
/// so a detached pump's eventual destroy still targets a valid
/// allocator after zonvie_core_destroy has done box.gpa.deinit().
pub const StderrPump = struct {
    alloc: std.mem.Allocator,
    f: rpc_transport.Stream,
    mu: std.Io.Mutex,
    core_users_done: std.Io.Condition,
    core: ?*Core,
    active_core_users: u32,
    refcount: std.atomic.Value(u32),
    cleanup_decided: bool,

    /// Drop one reference. When the count drops to zero, close the
    /// fd and free the struct. Safe to call from any thread.
    pub fn release(self: *StderrPump) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            self.f.close();
            self.alloc.destroy(self);
        }
    }

    /// Run the pump until EOF / read error. Called from the pump
    /// thread; never directly. Drops the thread's ref on exit.
    pub fn run(self: *StderrPump) void {
        defer self.finishRun();
        var buf: [4096]u8 = undefined;
        while (true) {
            // Stop check: Core may have flagged termination.
            const stop_core = self.acquireCore();
            const stopped = if (stop_core) |c| c.stop_flag.load(.seq_cst) else false;
            if (stop_core != null) self.releaseCore();
            if (stopped) break;

            const n = self.f.read(&buf) catch break;
            if (n == 0) break;

            // Hold a logical Core user while invoking callbacks, but never the
            // pump mutex itself. detachFromCore() prevents new users and waits
            // for active callbacks, preserving Core lifetime without making a
            // callback-safe stop() recurse into this mutex.
            const c = self.acquireCore() orelse continue;
            defer self.releaseCore();
            if (c.cb.on_log) |logfn| {
                log_mod.enterCallback();
                logfn(c.ctx, buf[0..n].ptr, n);
                log_mod.leaveCallback();
            }

            if (c.is_ssh_mode and !c.ssh_auth_done.load(.seq_cst)) {
                if (containsPasswordPrompt(buf[0..n])) {
                    c.log.write("SSH: detected password prompt in stderr\n", .{});
                    if (c.cb.on_ssh_auth_prompt) |prompt_cb| {
                        c.ssh_auth_pending.store(true, .seq_cst);
                        log_mod.enterCallback();
                        prompt_cb(c.ctx, "SSH Password:", 13);
                        log_mod.leaveCallback();
                    }
                }
            }
        }
    }

    fn finishRun(self: *StderrPump) void {
        self.mu.lockUncancelable(clock.io());
        while (!self.cleanup_decided) {
            self.core_users_done.waitUncancelable(clock.io(), &self.mu);
        }
        self.mu.unlock(clock.io());
        self.release();
    }

    /// Tell an EOF'd pump that cleanup retained no child for it to reap.
    pub fn finishCleanupDecision(self: *StderrPump) void {
        self.mu.lockUncancelable(clock.io());
        defer self.mu.unlock(clock.io());
        if (self.cleanup_decided) return;
        self.cleanup_decided = true;
        self.core_users_done.broadcast(clock.io());
    }

    fn acquireCore(self: *StderrPump) ?*Core {
        self.mu.lockUncancelable(clock.io());
        defer self.mu.unlock(clock.io());
        const c = self.core orelse return null;
        self.active_core_users += 1;
        return c;
    }

    fn releaseCore(self: *StderrPump) void {
        self.mu.lockUncancelable(clock.io());
        defer self.mu.unlock(clock.io());
        std.debug.assert(self.active_core_users > 0);
        self.active_core_users -= 1;
        if (self.active_core_users == 0) self.core_users_done.broadcast(clock.io());
    }

    /// Sever the pump's back-reference to Core under the pump's own
    /// mutex. After this returns, the pump will not dereference Core
    /// in any subsequent iteration, and the caller is free to deinit
    /// Core. Safe to call from any thread; caller MUST hold a ref to
    /// the pump for the duration of this call.
    pub fn detachFromCore(self: *StderrPump) void {
        self.mu.lockUncancelable(clock.io());
        defer self.mu.unlock(clock.io());
        self.core = null;
        while (self.active_core_users != 0) {
            self.core_users_done.waitUncancelable(clock.io(), &self.mu);
        }
    }
};

/// Check if data contains a password prompt (case-insensitive)
pub fn containsPasswordPrompt(data: []const u8) bool {
    // Convert to lowercase for comparison
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 1) {
        // Check for "password" (case-insensitive)
        const slice = data[i .. i + 8];
        if (eqlIgnoreCase(slice, "password")) {
            return true;
        }
    }
    // Also check for "passphrase"
    i = 0;
    while (i + 10 <= data.len) : (i += 1) {
        const slice = data[i .. i + 10];
        if (eqlIgnoreCase(slice, "passphrase")) {
            return true;
        }
    }
    return false;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

pub fn logEnvHints(self: *Core) void {
    if (self.log.cb == null) return;

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd: ?[]const u8 = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |p|
        std.mem.span(@as([*:0]const u8, @ptrCast(p)))
    else
        null;
    if (cwd) |s|
        self.log.write("cwd: {s}\n", .{s})
    else
        self.log.write("cwd: (unknown)\n", .{});

    const path_env = envVarOwned(self.alloc, "PATH") catch null;
    defer if (path_env) |s| self.alloc.free(s);
    if (path_env) |s|
        self.log.write("PATH: {s}\n", .{s})
    else
        self.log.write("PATH: (missing)\n", .{});
}

fn failRedrawRecovery(self: *Core, reason: anyerror) void {
    self.log.write("redraw recovery failed: {any}\n", .{reason});
    self.failHardRender(reason);
}

const max_redraw_recovery_attempts: u8 = 2;

fn handleRedrawFailure(self: *Core, reason: anyerror) void {
    // Reattaching replays the same authoritative Neovim state. A local hard
    // resource limit therefore cannot be healed by an epoch reset and would
    // otherwise produce an unbounded detach/attach loop.
    if (Core.isHardRenderFailure(reason)) {
        failRedrawRecovery(self, reason);
        return;
    }
    beginRedrawRecovery(self);
}

fn handleRpcStreamFailure(self: *Core, reason: anyerror) void {
    if (Core.isHardRenderFailure(reason)) self.failHardRender(reason);
}

fn requestRedrawRecoveryAttach(self: *Core) !void {
    // Serialize the attach size with the latest-wins resize state, matching the
    // initial session attach path.
    self.pending_resize_mu.lockUncancelable(clock.io());
    defer self.pending_resize_mu.unlock(clock.io());

    const rows = if (self.pending_resize_valid)
        self.pending_resize_rows
    else if (self.desired_resize_rows != 0)
        self.desired_resize_rows
    else
        @max(1, self.ui_attach_rows);
    const cols = if (self.pending_resize_valid)
        self.pending_resize_cols
    else if (self.desired_resize_cols != 0)
        self.desired_resize_cols
    else
        @max(1, self.ui_attach_cols);

    const id = try self.requestUiAttachTracked(rows, cols);
    self.redraw_recovery_attach_rows = rows;
    self.redraw_recovery_attach_cols = cols;
    self.redraw_recovery_msgid = id;
    self.redraw_recovery_state = .await_attach;
    self.log.write("redraw recovery: fresh ui_attach queued id={d} rows={d} cols={d}\n", .{ id, rows, cols });
}

fn beginRedrawRecovery(self: *Core) void {
    if (self.redraw_recovery_failed.load(.seq_cst) or self.redraw_recovery_state == .await_detach) return;
    if (self.redraw_recovery_attempts >= max_redraw_recovery_attempts) {
        failRedrawRecovery(self, error.RedrawRecoveryLimitExceeded);
        return;
    }
    self.redraw_recovery_attempts += 1;

    self.pending_resize_mu.lockUncancelable(clock.io());
    self.ui_attached.store(false, .seq_cst);
    self.pending_resize_mu.unlock(clock.io());
    const id = self.requestUiDetachTracked() catch |err| {
        failRedrawRecovery(self, err);
        return;
    };
    // Publishing this after sendRaw succeeds is safe: this function runs on
    // the sole RPC reader thread, so no response can be dispatched meanwhile.
    self.redraw_recovery_msgid = id;
    self.redraw_recovery_state = .await_detach;
    self.log.write("redraw recovery: poisoned UI epoch, detach queued id={d}\n", .{id});
}

fn handleRedrawRecoveryResponse(self: *Core, id: i64, has_err: bool) bool {
    if (id != self.redraw_recovery_msgid) return false;

    switch (self.redraw_recovery_state) {
        .healthy => return false,
        .await_detach => {
            if (has_err) {
                failRedrawRecovery(self, error.UiDetachFailed);
                return true;
            }

            // Every byte emitted by the old RemoteUI precedes this response on
            // the same channel. Reset only after crossing that boundary.
            self.resetRedrawProtocolState();
            requestRedrawRecoveryAttach(self) catch |err| failRedrawRecovery(self, err);
            return true;
        },
        .await_attach => {
            if (has_err) {
                failRedrawRecovery(self, error.UiAttachFailed);
                return true;
            }

            self.pending_resize_mu.lockUncancelable(clock.io());
            if (self.pending_resize_valid and
                self.pending_resize_rows == self.redraw_recovery_attach_rows and
                self.pending_resize_cols == self.redraw_recovery_attach_cols)
            {
                self.pending_resize_valid = false;
                self.pending_resize_sequence = 0;
            }
            self.ui_attach_rows = self.redraw_recovery_attach_rows;
            self.ui_attach_cols = self.redraw_recovery_attach_cols;
            self.ui_attached.store(true, .seq_cst);
            self.flushPendingUiStateLocked();
            self.pending_resize_mu.unlock(clock.io());

            self.redraw_recovery_state = .healthy;
            self.redraw_recovery_msgid = 0;
            self.redraw_recovery_attach_rows = 0;
            self.redraw_recovery_attach_cols = 0;
            // The tracked attach response is serialized after its full-state
            // replay. Only this boundary proves the recovery completed; an
            // earlier successful replay batch must not reset the retry limit
            // before a later batch reproduces the same deterministic error.
            self.redraw_recovery_attempts = 0;
            self.log.write("redraw recovery: fresh UI epoch attached\n", .{});
            return true;
        },
    }
}

pub fn handleRpcResponse(self: *Core, top: []mp.Value) void {
    // [type=1, msgid, error, result]
    if (top.len < 4) return;
    if (top[1] != .int) return;
    const id = top[1].int;

    const errv = top[2];
    const has_err = (errv != .nil);

    if (handleRedrawRecoveryResponse(self, id, has_err)) return;

    if (has_err) {
        self.log.write("rpc resp id={d} error={any}\n", .{ id, errv });
        // Clear quit_request_msgid if this was a failed quit request
        const pending_quit_id = self.quit_request_msgid.load(.acquire);
        if (pending_quit_id != 0 and id == pending_quit_id) {
            self.quit_request_msgid.store(0, .release);
            // On error, still try to quit (fallback)
            if (self.cb.on_quit_requested) |cb| {
                cb(self.ctx, 0); // Assume no unsaved on error
            }
        }
        // Glow config request error — decrement retry (next redraw will re-request)
        const pending_glow_id = self.glow_request_msgid.load(.acquire);
        if (pending_glow_id != 0 and id == pending_glow_id) {
            self.glow_request_msgid.store(0, .release);
            if (self.glow_startup_retries > 0) {
                self.glow_startup_retries -= 1;
            }
        }
        return;
    }

    // Check if this is quit request response
    const pending_quit_id = self.quit_request_msgid.load(.acquire);
    if (pending_quit_id != 0 and id == pending_quit_id) {
        self.quit_request_msgid.store(0, .release);

        // Log the response type for debugging
        self.log.write("quit request response: result type={s}\n", .{@tagName(top[3])});

        // Result is boolean: true if there are unsaved buffers
        const has_unsaved: bool = switch (top[3]) {
            .bool => |b| b,
            .int => |i| i != 0,
            else => false,
        };

        self.log.write("quit request response: has_unsaved={}\n", .{has_unsaved});

        // Notify frontend via callback
        if (self.cb.on_quit_requested) |cb| {
            cb(self.ctx, if (has_unsaved) 1 else 0);
        } else {
            // No callback - proceed with :qa (may fail if unsaved)
            self.quitConfirmed(false);
        }
        return;
    }

    // Check if this is glow config response
    const pending_glow_id = self.glow_request_msgid.load(.acquire);
    if (pending_glow_id != 0 and id == pending_glow_id) {
        self.glow_request_msgid.store(0, .release);
        self.log.write("glow config response received: type={s}\n", .{@tagName(top[3])});
        applyGlowConfig(self, top[3]);
        return;
    }
}

/// Force full vertex regeneration (content_rev bump + dirty_all + onFlush).
/// Used when glow state changes to ensure DECO_GLOW flags are set/cleared.
fn forceGlowFlush(self: *Core) void {
    // Owner id is set/cleared strictly inside the locked section — see the
    // matching comment in handleRpcNotification's "redraw" branch for why
    // (a store before lock or a clear after unlock opens a window where a
    // different thread, e.g. zonvie_core_retry_flush, can observe/clobber
    // this id while this thread's critical section is still in progress).
    self.grid_mu.lockUncancelable(clock.io());
    self.redraw_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
    self.grid.content_rev +%= 1;
    self.grid.markAllDirty();
    var sg_it = self.grid.sub_grids.valueIterator();
    while (sg_it.next()) |sg| sg.markAllDirty();
    self.force_ext_cursor_recheck = true;
    var fctx = flush.FlushCtx{ .core = self };
    flush.FlushCtx.onFlush(&fctx, self.grid.rows, self.grid.cols) catch |reason| {
        if (Core.isHardRenderFailure(reason)) self.failHardRender(reason);
    };
    self.redraw_thread_id.store(0, .seq_cst);
    self.grid_mu.unlock(clock.io());
}

/// Disable glow and flush if it was previously enabled (clears DECO_GLOW from vertices).
fn disableGlow(self: *Core) void {
    const was_enabled = self.glow_enabled.load(.acquire);
    self.glow_enabled.store(false, .release);
    if (was_enabled) {
        forceGlowFlush(self);
    }
}

/// Parse vim.g.zonvie_glow response and apply configuration.
/// Expected format: { groups = {"Keyword", "String", ...}, radius = 6, intensity = 0.6 }
fn applyGlowConfig(self: *Core, result: mp.Value) void {
    // Free old group names and reset glow_all
    self.freeGlowGroupNames();
    self.glow_all = false;

    // nil means variable is not set
    if (result == .nil) {
        disableGlow(self);
        if (self.glow_startup_retries > 0) {
            self.glow_startup_retries -= 1;
        }
        return;
    }

    // Must be a map/dict
    if (result != .map) {
        disableGlow(self);
        if (self.glow_startup_retries > 0) {
            self.glow_startup_retries -= 1;
        }
        self.log.write("glow config: unexpected type: {s}\n", .{@tagName(result)});
        return;
    }

    const map = result.map;
    var found_groups = false;

    for (map) |entry| {
        const key = if (entry.key == .str) entry.key.str else continue;

        if (std.mem.eql(u8, key, "groups")) {
            if (entry.val == .arr) {
                for (entry.val.arr) |item| {
                    if (item == .str) {
                        const duped = self.alloc.dupe(u8, item.str) catch continue;
                        self.glow_group_names.append(self.alloc, duped) catch {
                            self.alloc.free(duped);
                            continue;
                        };
                    }
                }
                found_groups = self.glow_group_names.items.len > 0;
            } else if (entry.val == .str and std.mem.eql(u8, entry.val.str, "all")) {
                // "all" means apply glow to every cell
                self.glow_all = true;
                found_groups = true;
            }
        } else if (std.mem.eql(u8, key, "radius")) {
            if (entry.val == .int) {
                const r: f32 = @floatFromInt(entry.val.int);
                self.glow_radius_px = std.math.clamp(r, 2.0, 16.0);
            } else if (entry.val == .float) {
                self.glow_radius_px = std.math.clamp(@as(f32, @floatCast(entry.val.float)), 2.0, 16.0);
            }
        } else if (std.mem.eql(u8, key, "intensity")) {
            if (entry.val == .int) {
                const i_val: f32 = @floatFromInt(entry.val.int);
                self.setGlowIntensity(std.math.clamp(i_val, 0.0, 1.0));
            } else if (entry.val == .float) {
                self.setGlowIntensity(std.math.clamp(@as(f32, @floatCast(entry.val.float)), 0.0, 1.0));
            }
        }
    }

    if (found_groups) {
        self.resolveGlowGroups();
        self.glow_startup_retries = 0;
        self.log.write("glow config: enabled, {d} groups, radius={d:.1}, intensity={d:.1}\n", .{
            self.glow_group_names.items.len, self.glow_radius_px, self.getGlowIntensity(),
        });
        forceGlowFlush(self);
    } else {
        disableGlow(self);
        self.log.write("glow config: disabled (no groups)\n", .{});
    }
}

pub fn handleRpcRequest(self: *Core, arena: std.mem.Allocator, top: []mp.Value) void {
    // [type=0, msgid, method, params]
    _ = arena;
    if (top.len < 4) return;
    if (top[1] != .int) return;
    if (top[2] != .str) return;

    const msgid = top[1].int;
    const method = top[2].str;

    self.log.write("rpc request: method={s} msgid={d}\n", .{ method, msgid });

    if (std.mem.eql(u8, method, "zonvie.get_clipboard")) {
        handleClipboardGet(self, msgid, top[3]);
    } else if (std.mem.eql(u8, method, "zonvie.set_clipboard")) {
        handleClipboardSet(self, msgid, top[3]);
    } else if (std.mem.eql(u8, method, "win_move_cursor")) {
        handleWinMoveCursor(self, msgid, top[3]);
    } else {
        // Unknown method - send error response
        sendRpcErrorResponse(self, msgid, "Unknown method") catch |e| {
            self.log.write("sendRpcErrorResponse failed: {any}\n", .{e});
        };
    }
}

pub fn handleClipboardGet(self: *Core, msgid: i64, params: mp.Value) void {
    // params = [register_name] (e.g. "+" or "*")
    var register: []const u8 = "+";
    if (params == .arr and params.arr.len >= 1) {
        if (params.arr[0] == .str) {
            register = params.arr[0].str;
        }
    }

    self.log.write("clipboard get: register={s}\n", .{register});

    // Call frontend callback.
    //
    // The callback reports the total size available, not the amount it wrote,
    // so a register larger than the staging buffer is detected rather than
    // silently cut in half (and, for UTF-8, cut mid-sequence). The common
    // paste fits the stack buffer and costs no allocation; only an oversized
    // one takes the heap path.
    if (self.cb.on_clipboard_get) |cb| {
        var stack_buf: [64 * 1024]u8 = undefined;
        var out_len: usize = 0;

        if (cb(self.ctx, register.ptr, &stack_buf, &out_len, stack_buf.len) != 0) {
            if (out_len <= stack_buf.len) {
                sendClipboardGetResponse(self, msgid, stack_buf[0..out_len]) catch |e| {
                    self.log.write("sendClipboardGetResponse failed: {any}\n", .{e});
                };
                return;
            }

            // The clipboard can change between the sizing call and the fetch,
            // so allow a few rounds before giving up rather than looping on a
            // target that keeps moving.
            var rounds: u8 = 0;
            while (rounds < 3) : (rounds += 1) {
                const heap = self.alloc.alloc(u8, out_len) catch break;
                defer self.alloc.free(heap);

                out_len = 0;
                if (cb(self.ctx, register.ptr, heap.ptr, &out_len, heap.len) == 0) break;
                if (out_len <= heap.len) {
                    sendClipboardGetResponse(self, msgid, heap[0..out_len]) catch |e| {
                        self.log.write("sendClipboardGetResponse failed: {any}\n", .{e});
                    };
                    return;
                }
            }
            self.log.write(
                "clipboard get: could not obtain {d} bytes, returning empty\n",
                .{out_len},
            );
        }
    }

    // Failure - send empty result
    sendClipboardGetResponse(self, msgid, "") catch |e| {
        self.log.write("sendClipboardGetResponse (empty) failed: {any}\n", .{e});
    };
}

pub fn handleClipboardSet(self: *Core, msgid: i64, params: mp.Value) void {
    // params = [register_name, lines_array]
    if (params != .arr or params.arr.len < 2) {
        sendRpcErrorResponse(self, msgid, "Invalid params") catch {};
        return;
    }

    var register: []const u8 = "+";
    if (params.arr[0] == .str) {
        register = params.arr[0].str;
    }

    self.log.write("clipboard set: register={s}\n", .{register});

    // Convert lines array to newline-separated string.
    //
    // Sized exactly and heap-allocated rather than staged through a fixed
    // buffer: a register that did not fit used to have the offending lines
    // dropped while later lines were still appended, so the content lost its
    // middle with the line structure intact — and the response still said the
    // copy succeeded. A whole-register yank is not a per-frame path, so the
    // allocation is cheap relative to reporting a truncated clipboard as good.
    // The size is already bounded upstream by the RPC frame and blob caps.
    var content: []u8 = &.{};
    var content_len: usize = 0;
    var owned = false;
    defer if (owned) self.alloc.free(content);

    if (params.arr[1] == .arr) {
        const lines = params.arr[1].arr;

        // Both loops must agree on which elements contribute, so they share
        // their predicates verbatim.
        var needed: usize = 0;
        for (lines, 0..) |line, i| {
            if (line == .str) {
                needed += line.str.len;
                if (i < lines.len - 1) needed += 1;
            }
        }

        // The callback takes a pointer even for an empty register; keep it
        // valid without special-casing the caller.
        content = self.alloc.alloc(u8, @max(needed, 1)) catch {
            sendRpcErrorResponse(self, msgid, "Clipboard allocation failed") catch {};
            return;
        };
        owned = true;

        for (lines, 0..) |line, i| {
            if (line == .str) {
                const line_str = line.str;
                @memcpy(content[content_len..][0..line_str.len], line_str);
                content_len += line_str.len;
                // Add newline between lines (not after last)
                if (i < lines.len - 1) {
                    content[content_len] = '\n';
                    content_len += 1;
                }
            }
        }
    }

    // Call frontend callback
    if (self.cb.on_clipboard_set) |cb| {
        const data: [*]const u8 = if (owned) content.ptr else "";
        const result = cb(self.ctx, register.ptr, data, content_len);
        sendRpcBoolResponse(self, msgid, result != 0) catch |e| {
            self.log.write("sendRpcBoolResponse failed: {any}\n", .{e});
        };
        return;
    }

    sendRpcErrorResponse(self, msgid, "Clipboard not available") catch {};
}

pub fn sendRpcErrorResponse(self: *Core, msgid: i64, err_msg: []const u8) !void {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(self.alloc);

    try rpc.packArray(&buf, self.alloc, 4);
    try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
    try rpc.packInt(&buf, self.alloc, msgid);
    try rpc.packStr(&buf, self.alloc, err_msg); // error
    try rpc.packNil(&buf, self.alloc); // result

    try self.sendRaw(buf.items);
    self.log.write("rpc error response sent: msgid={d} err={s}\n", .{ msgid, err_msg });
}

pub fn sendRpcBoolResponse(self: *Core, msgid: i64, value: bool) !void {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(self.alloc);

    try rpc.packArray(&buf, self.alloc, 4);
    try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
    try rpc.packInt(&buf, self.alloc, msgid);
    try rpc.packNil(&buf, self.alloc); // no error
    try rpc.packBool(&buf, self.alloc, value); // result

    try self.sendRaw(buf.items);
    self.log.write("rpc bool response sent: msgid={d} value={}\n", .{ msgid, value });
}

pub fn handleWinMoveCursor(self: *Core, msgid: i64, params: mp.Value) void {
    // params: [direction, count]
    // direction: 0=down, 1=up, 2=right, 3=left
    // Returns: Integer (Neovim window handle of target window)
    var direction: i32 = 0;
    var count: i32 = 1;

    if (params == .arr and params.arr.len >= 2) {
        if (params.arr[0] == .int) direction = redraw.checkedI32(params.arr[0].int) orelse 0;
        if (params.arr[1] == .int) count = redraw.checkedI32(params.arr[1].int) orelse 1;
    }

    self.log.write("[win_move_cursor] direction={d} count={d}\n", .{ direction, count });

    var target_win: i64 = 0;
    if (self.cb.on_win_move_cursor) |cb| {
        target_win = cb(self.ctx, direction, count);
    }

    sendRpcIntResponse(self, msgid, target_win) catch |e| {
        self.log.write("sendRpcIntResponse failed: {any}\n", .{e});
    };
}

pub fn sendRpcIntResponse(self: *Core, msgid: i64, value: i64) !void {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(self.alloc);

    try rpc.packArray(&buf, self.alloc, 4);
    try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
    try rpc.packInt(&buf, self.alloc, msgid);
    try rpc.packNil(&buf, self.alloc); // no error
    try rpc.packInt(&buf, self.alloc, value); // result

    try self.sendRaw(buf.items);
    self.log.write("rpc int response sent: msgid={d} value={d}\n", .{ msgid, value });
}

pub fn sendClipboardGetResponse(self: *Core, msgid: i64, content: []const u8) !void {
    // Response format: [[line1, line2, ...], regtype]
    // regtype: "v" (charwise), "V" (linewise)
    var buf: rpc.Buf = .empty;
    defer buf.deinit(self.alloc);

    try rpc.packArray(&buf, self.alloc, 4);
    try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
    try rpc.packInt(&buf, self.alloc, msgid);
    try rpc.packNil(&buf, self.alloc); // no error

    // Result: [[lines...], regtype]
    try rpc.packArray(&buf, self.alloc, 2);

    // Split content by newlines into array
    var line_count: usize = 1;
    for (content) |c| {
        if (c == '\n') line_count += 1;
    }

    try rpc.packArray(&buf, self.alloc, line_count);

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            // Strip a trailing CR so CRLF clipboard text (Windows) does not
            // leave a stray \r that nvim renders as ^M.
            var line_end = i;
            if (line_end > line_start and content[line_end - 1] == '\r') line_end -= 1;
            try rpc.packStr(&buf, self.alloc, content[line_start..line_end]);
            line_start = i + 1;
        }
    }

    // regtype: "V" if ends with newline, "v" otherwise
    const regtype: []const u8 = if (content.len > 0 and content[content.len - 1] == '\n') "V" else "v";
    try rpc.packStr(&buf, self.alloc, regtype);

    try self.sendRaw(buf.items);
    self.log.write("clipboard get response sent: msgid={d} lines={d} regtype={s}\n", .{ msgid, line_count, regtype });
}

pub fn setupClipboard(self: *Core) void {
    if (self.clipboard_setup_done) return;

    // Discover our channel_id from Lua by scanning nvim_list_chans() for
    // the channel whose client.name == "zonvie" (set by the preceding
    // requestSetClientInfo on the same RPC pipe, so it's guaranteed to
    // be visible by the time nvim processes this exec_lua).
    //
    // This avoids the nvim_get_api_info round-trip that main used:
    // clipboard setup is fire-and-forget, no extra RPC cycle needed.
    // vim.api.nvim_get_api_info is not available from Lua in Neovim 0.11+,
    // and vim.fn.chanNr does not exist — nvim_list_chans is the only
    // reliable Lua-side mechanism.
    const lua_code =
        \\local ch
        \\for _, c in ipairs(vim.api.nvim_list_chans()) do
        \\  if c.client and c.client.name == 'zonvie' then
        \\    ch = c.id
        \\    break
        \\  end
        \\end
        \\if not ch then return end
        \\vim.g.zonvie_channel = ch
        \\vim.schedule(function()
        \\  vim.g.clipboard = {
        \\    name = 'zonvie',
        \\    copy = {
        \\      ['+'] = function(lines, regtype)
        \\        return vim.rpcrequest(ch, 'zonvie.set_clipboard', '+', lines)
        \\      end,
        \\      ['*'] = function(lines, regtype)
        \\        return vim.rpcrequest(ch, 'zonvie.set_clipboard', '*', lines)
        \\      end,
        \\    },
        \\    paste = {
        \\      ['+'] = function()
        \\        return vim.rpcrequest(ch, 'zonvie.get_clipboard', '+')
        \\      end,
        \\      ['*'] = function()
        \\        return vim.rpcrequest(ch, 'zonvie.get_clipboard', '*')
        \\      end,
        \\    },
        \\  }
        \\end)
    ;

    self.requestExecLua(lua_code) catch |e| {
        self.log.write("setupClipboard: requestExecLua failed: {any}\n", .{e});
        return;
    };

    self.clipboard_setup_done = true;
    self.log.write("clipboard setup done (via nvim_list_chans lookup)\n", .{});
}

/// Inject the AI-agent tab-status reporter into the connected Neovim so the
/// feature needs no user-side config. Classifies each terminal's OSC title into
/// a per-tabpage state and reports it via the zonvie_agent_status notification:
///   0=none  1=idle (agent present)  2=working/claude  3=working/braille(codex).
/// Agent presence + kind are latched per buffer (claude is recognized by its
/// '✳' U+2733 idle marker, its U+25D0..U+25D3 rotating-circle working spinner,
/// or "Claude" in the title; anything else with a Braille spinner is treated as
/// codex/generic). The frontend renders/animates from the low 7 bits of the
/// wire state.
/// Bit 7 (0x80) of the wire state is a "fire the OS notification now" flag,
/// only ever set together with base state 1 (finished) or 4 (needs input).
/// Completion is edge-detected per BUFFER (prevb[]), not per tab, because a
/// buffer keeps its identity while hidden but a tab's derived state does not
/// -- reporting only to tabs currently displaying the buffer (as the
/// indicator does) would silently drop the notification whenever the agent's
/// window got switched to something else while it worked. If no tab
/// currently shows the buffer when a notify-worthy edge fires, buftab[]
/// (the last tab seen showing it) is used as a fallback delivery target.
/// augroup clear=true keeps re-injection idempotent. Fire-and-forget.
pub fn setupAgentStatus(self: *Core) void {
    // Skip the reporter entirely when both the indicator and the completion
    // notification are disabled -- nothing would consume the status updates.
    if (!self.msg_config.tabline.agent_indicator and !self.msg_config.tabline.agent_notification) return;
    const lua_code =
        \\local present, kind, last, bufstate, buftitle = {}, {}, {}, {}, {}
        \\-- prevb: per-buffer previous state, used to edge-detect a completion
        \\-- worth an OS notification. Per-buffer (not per-tab) because a buffer
        \\-- keeps its identity while hidden, unlike a tab's derived state.
        \\-- buftab: last tab observed to display this buffer, used as a fallback
        \\-- delivery target when a completion happens while the buffer is hidden.
        \\local prevb, buftab = {}, {}
        \\-- Scrape the terminal tail for a pending decision prompt (permission /
        \\-- yes-no / numbered choice). This is how an agent "waiting for the user"
        \\-- is told apart from "done"; the title alone can't (both look idle).
        \\-- Conservative, English-string patterns -- fragile by nature.
        \\local function waiting_prompt(buf)
        \\  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, -60, -1, false)
        \\  if not ok then return false end
        \\  while #lines > 0 and lines[#lines]:match('^%s*$') do lines[#lines] = nil end
        \\  if #lines == 0 then return false end
        \\  local t = table.concat(lines, '\n', math.max(1, #lines - 19), #lines)
        \\  -- Selection-menu footer (AskUserQuestion / ExitPlanMode / permission):
        \\  -- present only while an interactive prompt is on screen, language-agnostic.
        \\  return t:find('Enter to select') ~= nil or t:find('to navigate') ~= nil
        \\    or t:find('Esc to cancel') ~= nil or t:find('Do you want') ~= nil
        \\    or t:find('to proceed') ~= nil or t:find('tell Claude') ~= nil
        \\    or t:find('%[y/n%]') ~= nil or t:find('Allow command') ~= nil
        \\end
        \\-- Leading marker of an agent's OSC title. Claude Code animates a
        \\-- rotating circle (U+25D0..U+25D3) while working and shows the '✳'
        \\-- U+2733 star when idle; codex and generic agents animate a Braille
        \\-- spinner. While Claude works, the title body is its task summary --
        \\-- the word "Claude" is absent -- so the circle is the only thing that
        \\-- keeps the tab from looking like the agent exited.
        \\local function marker(title)
        \\  local cp = title ~= '' and vim.fn.char2nr(title) or 0
        \\  if cp >= 0x2800 and cp <= 0x28FF then return 'braille' end
        \\  if cp >= 0x25D0 and cp <= 0x25D3 then return 'circle' end
        \\  if cp == 0x2733 then return 'idle' end
        \\  return nil
        \\end
        \\local function spinning(title)
        \\  local m = marker(title)
        \\  return m == 'braille' or m == 'circle'
        \\end
        \\-- classify returns 2/3 = working, 0 = gone, 1 = present-but-stopped
        \\-- (done OR waiting -- decided later by a deferred scrape, because the
        \\-- prompt box may not be in the buffer yet at the instant the spinner stops).
        \\local function classify(buf, title)
        \\  local m = marker(title)
        \\  local spin = m == 'braille' or m == 'circle'
        \\  local claudeish = m == 'idle' or m == 'circle' or title:find('Claude') ~= nil
        \\  if claudeish then present[buf] = true; kind[buf] = 'claude' end
        \\  if spin then present[buf] = true; if not kind[buf] then kind[buf] = 'braille' end end
        \\  if spin then return (kind[buf] == 'claude') and 2 or 3 end
        \\  if claudeish then return 1 end
        \\  -- Claude always shows the U+2733 marker when idle; a claude tab whose
        \\  -- title lost every agent marker means Claude exited (the shell took the
        \\  -- title over, e.g. cmd.exe) -> clear so the robot indicator goes away.
        \\  if kind[buf] == 'claude' then present[buf] = nil; kind[buf] = nil; return 0 end
        \\  if present[buf] then return 1 end
        \\  return 0
        \\end
        \\local function tabs_for_buf(buf)
        \\  local out = {}
        \\  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        \\    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
        \\      if vim.api.nvim_win_get_buf(w) == buf then out[#out+1] = t; break end
        \\    end
        \\  end
        \\  if #out > 0 then buftab[buf] = out[1] end
        \\  return out
        \\end
        \\-- notify (bit 7 of the wire state) tells the frontend to fire its OS
        \\-- notification now, instead of inferring the edge itself from a
        \\-- per-tab prev-state map (which breaks once the agent's buffer is
        \\-- hidden -- see deliver() below). A notify report bypasses the
        \\-- per-tab debounce, since it must fire even if last[tab] already
        \\-- equals the base state.
        \\local function report(tab, state, title, notify)
        \\  if not notify and last[tab] == state then return end
        \\  last[tab] = state
        \\  vim.rpcnotify(0, 'zonvie_agent_status',
        \\    { tab = tab, state = notify and (state + 128) or state, title = title or '' })
        \\end
        \\-- Rank states so a tab with several agent buffers surfaces the most
        \\-- active one: working (2/3) > waiting (4) > done (1) > none (0).
        \\local function rank(s) return ({ [2] = 3, [3] = 3, [4] = 2, [1] = 1 })[s] or 0 end
        \\-- The agent state a tab should show right now, aggregated from the
        \\-- present terminal buffers currently displayed in its windows.
        \\local function tab_agent_state(tab)
        \\  local best, bt = 0, ''
        \\  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        \\    local b = vim.api.nvim_win_get_buf(w)
        \\    if present[b] and bufstate[b] and rank(bufstate[b]) > rank(best) then
        \\      best = bufstate[b]; bt = buftitle[b] or ''
        \\    end
        \\  end
        \\  return best, bt
        \\end
        \\-- Re-derive every tab's indicator from the live window layout. Runs on
        \\-- window/buffer switches so the indicator drops when a tab no longer
        \\-- shows its agent terminal (e.g. the window switched to a normal buffer).
        \\local function refresh_tabs()
        \\  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        \\    local s, bt = tab_agent_state(t)
        \\    report(t, s, bt)
        \\  end
        \\end
        \\-- Deliver a buffer's state to the tabs currently showing it. If none
        \\-- show it (the agent's window was switched to something else) and this
        \\-- is a notify-worthy report, fall back to the last tab known to have
        \\-- shown the buffer so the OS notification isn't lost -- then re-derive
        \\-- that tab's indicator from the live layout right after, since the
        \\-- fallback report otherwise leaves it showing a stale base state.
        \\local function deliver(buf, s, title, notify)
        \\  bufstate[buf] = s; buftitle[buf] = title
        \\  local tabs = tabs_for_buf(buf)
        \\  if #tabs == 0 then
        \\    if notify then
        \\      local t = buftab[buf]
        \\      if t and vim.api.nvim_tabpage_is_valid(t) then
        \\        report(t, s, title, true)
        \\        vim.schedule(refresh_tabs)
        \\      end
        \\    end
        \\    return
        \\  end
        \\  for _, tab in ipairs(tabs) do report(tab, s, title, notify) end
        \\end
        \\-- The done-vs-waiting decision is deferred ~0.8s after the spinner stops,
        \\-- so the prompt box has time to render into the buffer before we scrape.
        \\-- pend[buf] is a token that any newer event bumps to cancel a stale decision.
        \\local pend = {}
        \\local function decide_stopped(buf, title)
        \\  pend[buf] = (pend[buf] or 0) + 1
        \\  local tok = pend[buf]
        \\  vim.defer_fn(function()
        \\    if pend[buf] ~= tok then return end
        \\    if not (vim.api.nvim_buf_is_valid(buf) and present[buf]) then return end
        \\    local ok, t = pcall(function() return vim.b[buf].term_title end)
        \\    if ok and spinning(t or '') then return end
        \\    local s = waiting_prompt(buf) and 4 or 1
        \\    local p = prevb[buf]
        \\    prevb[buf] = s
        \\    -- Completion edge worth an OS notification: agent was working and
        \\    -- stopped (done or waiting), or a waiting agent's turn ended
        \\    -- without another working title in between (answered and done).
        \\    local notify = ((p == 2 or p == 3) and (s == 1 or s == 4)) or (p == 4 and s == 1)
        \\    deliver(buf, s, title, notify)
        \\    -- Second chance: the prompt box can render later than 800ms after
        \\    -- the spinner stops. Re-scrape once more; upgrade 1 -> 4 only
        \\    -- (never downgrade an already-decided 4 back to 1).
        \\    if s == 1 then
        \\      vim.defer_fn(function()
        \\        if pend[buf] ~= tok then return end
        \\        if not (vim.api.nvim_buf_is_valid(buf) and present[buf]) then return end
        \\        local ok2, t2 = pcall(function() return vim.b[buf].term_title end)
        \\        if ok2 and spinning(t2 or '') then return end
        \\        if waiting_prompt(buf) then
        \\          prevb[buf] = 4
        \\          deliver(buf, 4, title, true)
        \\        end
        \\      end, 1700)
        \\    end
        \\  end, 800)
        \\end
        \\local grp = vim.api.nvim_create_augroup('zonvie_agent_status', { clear = true })
        \\vim.api.nvim_create_autocmd('TermRequest', {
        \\  group = grp,
        \\  callback = function(ev)
        \\    local seq = ev.data and ev.data.sequence or ''
        \\    local body = seq:match('^\27%]0;(.*)$') or seq:match('^\27%]1;(.*)$') or seq:match('^\27%]2;(.*)$')
        \\    if not body then return end
        \\    local s = classify(ev.buf, body)
        \\    local title = marker(body) and (body:gsub('^[^ ]+%s*', '')) or body
        \\    if s == 1 then
        \\      decide_stopped(ev.buf, title)
        \\    else
        \\      pend[ev.buf] = (pend[ev.buf] or 0) + 1
        \\      prevb[ev.buf] = (s ~= 0) and s or nil
        \\      deliver(ev.buf, s, title, false)
        \\    end
        \\  end,
        \\})
        \\vim.api.nvim_create_autocmd('TermClose', {
        \\  group = grp,
        \\  callback = function(ev)
        \\    pend[ev.buf] = (pend[ev.buf] or 0) + 1
        \\    present[ev.buf] = nil; kind[ev.buf] = nil; bufstate[ev.buf] = nil; buftitle[ev.buf] = nil
        \\    prevb[ev.buf] = nil; buftab[ev.buf] = nil
        \\    for _, tab in ipairs(tabs_for_buf(ev.buf)) do report(tab, 0) end
        \\  end,
        \\})
        \\-- Agent state is latched per buffer but shown per tab, so a tab's
        \\-- indicator must be re-derived whenever its window layout changes --
        \\-- otherwise switching a window away from the agent terminal leaves a
        \\-- stale indicator on the tab.
        \\vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufWinLeave', 'WinEnter', 'WinClosed' }, {
        \\  group = grp,
        \\  callback = function() vim.schedule(refresh_tabs) end,
        \\})
        \\-- Agent exit (claude/codex quit while the shell stays open) clears the
        \\-- terminal title to "" but fires NO TermRequest, so poll present
        \\-- buffers and drop the indicator when the title goes empty.
        \\if _G.__zonvie_agent_timer then pcall(vim.fn.timer_stop, _G.__zonvie_agent_timer) end
        \\_G.__zonvie_agent_timer = vim.fn.timer_start(500, function()
        \\  for buf in pairs(present) do
        \\    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == 'terminal' then
        \\      local ok, t = pcall(function() return vim.b[buf].term_title end)
        \\      t = (ok and t) or ''
        \\      local agentish = marker(t) ~= nil or t:find('Claude') ~= nil
        \\      -- Gone if the title is empty (zsh after exit), or a claude tab no
        \\      -- longer shows any agent marker (cmd.exe took the title over).
        \\      if t == '' or (kind[buf] == 'claude' and not agentish) then
        \\        pend[buf] = (pend[buf] or 0) + 1
        \\        present[buf] = nil; kind[buf] = nil; bufstate[buf] = nil; buftitle[buf] = nil
        \\        prevb[buf] = nil; buftab[buf] = nil
        \\        for _, tab in ipairs(tabs_for_buf(buf)) do report(tab, 0) end
        \\      end
        \\    else
        \\      pend[buf] = (pend[buf] or 0) + 1
        \\      present[buf] = nil; kind[buf] = nil; bufstate[buf] = nil; buftitle[buf] = nil
        \\      prevb[buf] = nil; buftab[buf] = nil
        \\    end
        \\  end
        \\end, { ['repeat'] = -1 })
    ;

    self.requestExecLua(lua_code) catch |e| {
        self.log.write("setupAgentStatus: requestExecLua failed: {any}\n", .{e});
        return;
    };
    self.log.write("agent status reporter installed\n", .{});
}

/// Report the 'ver' component of 'mousescroll' — how many rows one wheel
/// event scrolls — and keep reporting it when the option changes.
///
/// The trackpad's sub-cell scrolling has to know this: it asks Neovim for
/// rows before the finger has travelled them and cancels each arrival against
/// the pixel offset it holds, so an event worth N rows must be accounted as N
/// rows of travel. Assuming one row made a fast gesture jump, because the
/// lookahead paid for one row while the content moved N.
///
/// 'ver:0' disables mouse scrolling entirely (it is not a page-relative
/// setting) and reports 0; the frontend then has no row count to reason with
/// and leaves the precise path alone. A setting with no 'ver' component at all
/// reports 3, matching the default Neovim uses for an omitted direction — the
/// Lua fallback is for a missing component, never for an explicit 0.
/// augroup clear=true keeps re-injection idempotent. Fire-and-forget.
///
/// macOS only: sub-cell trackpad scrolling is a macOS frontend feature, and
/// the Windows frontend scrolls by whole rows, so injecting the reporter
/// there would cost an exec_lua and an autocmd for a value nothing reads.
pub fn setupMouseScrollReporter(self: *Core) void {
    if (comptime builtin.os.tag != .macos) return;
    const lua_code =
        \\local function report()
        \\  local ms = vim.o.mousescroll or ''
        \\  local n = tonumber(ms:match('ver:(%d+)'))
        \\  vim.rpcnotify(0, 'zonvie_mousescroll', n or 3)
        \\end
        \\report()
        \\local grp = vim.api.nvim_create_augroup('zonvie_mousescroll', { clear = true })
        \\vim.api.nvim_create_autocmd('OptionSet', {
        \\  group = grp,
        \\  pattern = 'mousescroll',
        \\  callback = function() report() end,
        \\})
    ;

    self.requestExecLua(lua_code) catch |e| {
        self.log.write("setupMouseScrollReporter: requestExecLua failed: {any}\n", .{e});
        return;
    };
    self.log.write("mousescroll reporter installed\n", .{});
}

/// Borrow 'smoothscroll' for the duration of a trackpad gesture, and hand it
/// back when the gesture ends.
///
/// Without it a 'wrap'ped window can only move a whole buffer line at a time,
/// which is however many screen rows that line occupies — measured, one wheel
/// event books 3 rows and moves 12. No amount of frontend accounting smooths
/// that: the picture either jumps at every wrapped line or the offset runs away
/// from the finger. With 'smoothscroll' the quantum becomes one screen row and
/// a wheel event moves exactly the 'mousescroll' count, so booking and movement
/// agree and the sub-cell model holds.
///
/// The previous value is stashed in a window variable and restored from it, so
/// a restore that arrives twice is harmless. One that never arrives leaves the
/// stash behind, and the borrow does NOT undo that by itself — the stash makes
/// the next enable a no-op, so recovery takes a whole further gesture over that
/// window, borrow and hand-back both.
///
/// Windows without 'wrap' are skipped, where the option would do nothing — but
/// 'wrap' is on by default, so that is not the common case. Expect TWO
/// OptionSet events per gesture on a normally configured window (the borrow and
/// the restore are each a set, and Neovim fires OptionSet even when the value
/// does not change), which user config can observe.
///
/// macOS only: sub-cell trackpad scrolling is a macOS frontend feature.
///
/// Returns false when the request could not be issued — the grid lock was busy,
/// or no window is known yet. Called from the input path, so it never blocks on
/// the lock; the caller is expected to try again, which matters most for the
/// restore.
pub fn setGestureSmoothScroll(self: *Core, grid_id: i64, enable: bool) bool {
    if (comptime builtin.os.tag != .macos) return true;

    const win = blk: {
        if (!self.grid_mu.tryLock()) {
            self.log.write("[ss_borrow] grid={d} enable={any} lock busy\n", .{ grid_id, enable });
            return false;
        }
        defer self.grid_mu.unlock(clock.io());
        const vp = self.grid.getViewport(grid_id) orelse break :blk 0;
        break :blk vp.win;
    };
    if (win == 0) {
        // Reported as done, not as busy. No window means the grid is gone —
        // its window-local option and the stash went with it, so there is
        // nothing left to restore and a caller retrying would do so forever.
        self.log.write("[ss_borrow] grid={d} enable={any} no window\n", .{ grid_id, enable });
        return true;
    }

    const enable_lua =
        \\local w = {d}
        \\if vim.api.nvim_win_is_valid(w)
        \\  and vim.api.nvim_get_option_value('wrap', {{ win = w }})
        \\  and not pcall(vim.api.nvim_win_get_var, w, 'zonvie_ss_prev') then
        \\  vim.api.nvim_win_set_var(w, 'zonvie_ss_prev',
        \\    vim.api.nvim_get_option_value('smoothscroll', {{ win = w }}))
        \\  vim.api.nvim_set_option_value('smoothscroll', true, {{ win = w }})
        \\end
    ;
    const restore_lua =
        \\local w = {d}
        \\if vim.api.nvim_win_is_valid(w) then
        \\  local ok, prev = pcall(vim.api.nvim_win_get_var, w, 'zonvie_ss_prev')
        \\  if ok then
        \\    pcall(vim.api.nvim_set_option_value, 'smoothscroll', prev, {{ win = w }})
        \\    pcall(vim.api.nvim_win_del_var, w, 'zonvie_ss_prev')
        \\  end
        \\end
    ;

    var buf: [640]u8 = undefined;
    const lua_code = (if (enable)
        std.fmt.bufPrint(&buf, enable_lua, .{win})
    else
        std.fmt.bufPrint(&buf, restore_lua, .{win})) catch return false;

    self.requestExecLua(lua_code) catch |e| {
        self.log.write("[ss_borrow] grid={d} win={d} enable={any} exec_lua failed: {any}\n", .{ grid_id, win, enable, e });
        return false;
    };
    self.log.write("[ss_borrow] grid={d} win={d} enable={any} issued\n", .{ grid_id, win, enable });
    return true;
}

fn prepareRenderStateForFlush(ctx: *flush.FlushCtx) !void {
    const self = ctx.core;

    // hl_group_set changes can alter decoration geometry. Resolve them before
    // vertex generation so the flush that terminates this redraw batch carries
    // the new glow state.
    if (self.hl.groups_changed) {
        self.hl.groups_changed = false;
        self.resolveGlowGroups();
        if (self.glow_enabled.load(.acquire)) {
            self.grid.markAllDirty();
            var sg_it = self.grid.sub_grids.valueIterator();
            while (sg_it.next()) |sg| sg.markAllDirty();
            self.force_ext_cursor_recheck = true;
        }
    }

    // Promote an external editor grid before the frontend transaction. A
    // successful flush must represent the final composition state of the
    // redraw batch; changing win_pos after commit can otherwise stay invisible
    // indefinitely when Neovim goes idle.
    var ext_windows_promoted = false;
    if (self.ext_windows_enabled and self.grid.ext_windows_grids.count() > 0) {
        var has_composited_editor_win = false;
        var only_grid2_composited = true;
        var wp_it = self.grid.win_pos.keyIterator();
        while (wp_it.next()) |key_ptr| {
            const gid = key_ptr.*;
            if (gid == 1) continue;
            if (self.grid.win_layer.contains(gid)) continue;
            if (self.grid.external_grids.contains(gid)) continue;
            if (!self.grid.grid_win_ids.contains(gid)) continue;
            has_composited_editor_win = true;
            if (gid != 2) only_grid2_composited = false;
        }

        if (has_composited_editor_win and self.grid.composited_win_closed and only_grid2_composited) {
            try self.grid.hideWin(2);
            has_composited_editor_win = false;
            self.log.write("[ext_windows_promote] removed fallback grid 2 (composited_win_closed)\n", .{});
        }
        self.grid.composited_win_closed = false;

        if (!has_composited_editor_win) {
            const PromoteEntry = struct {
                grid_id: i64,
                win_id: i64,
                row: u32,
                col: u32,
            };
            var promote_target: ?PromoteEntry = null;
            var fallback_target: ?PromoteEntry = null;
            var ew_it = self.grid.ext_windows_grids.iterator();
            while (ew_it.next()) |entry| {
                const gid = entry.key_ptr.*;
                const ext_info = self.grid.external_grids.get(gid) orelse continue;
                const candidate: PromoteEntry = .{
                    .grid_id = gid,
                    .win_id = entry.value_ptr.*,
                    .row = if (ext_info.start_row >= 0) @intCast(ext_info.start_row) else 0,
                    .col = if (ext_info.start_col >= 0) @intCast(ext_info.start_col) else 0,
                };
                if (ext_info.start_row >= 0 and ext_info.start_col >= 0) {
                    promote_target = candidate;
                    break;
                }
                if (fallback_target == null) fallback_target = candidate;
            }
            if (promote_target == null) promote_target = fallback_target;

            if (promote_target) |p| {
                try self.grid.promoteExternalToWinPos(p.grid_id, p.win_id, p.row, p.col);
                _ = self.grid.ext_windows_grids.remove(p.grid_id);
                _ = self.grid.external_grid_target_sizes.remove(p.grid_id);
                _ = self.grid.pending_ext_window_grids.remove(p.grid_id);
                try self.grid.resizeGrid(p.grid_id, self.grid.rows, self.grid.cols);
                try self.requestTryResizeGridInternal(p.grid_id, self.grid.rows, self.grid.cols);
                self.log.write(
                    "[ext_windows_promote] promoted grid={d} win={d} at ({d},{d}), resized to {d}x{d}\n",
                    .{ p.grid_id, p.win_id, p.row, p.col, self.grid.rows, self.grid.cols },
                );
                ext_windows_promoted = true;
                self.grid.markAllDirty();
            }
        }
    } else {
        self.grid.composited_win_closed = false;
    }

    // Neovim can omit win_pos for the default editor grid with ext_windows.
    // Install the fallback before vertex generation, unless a promoted editor
    // grid already occupies the main surface.
    if (!ext_windows_promoted and
        !self.grid.win_pos.contains(2) and
        !self.grid.ext_windows_grids.contains(2))
    {
        var has_other_editor_grid = false;
        var wp_chk = self.grid.win_pos.keyIterator();
        while (wp_chk.next()) |key_ptr| {
            const gid = key_ptr.*;
            if (gid == 1 or gid == 2) continue;
            if (self.grid.win_layer.contains(gid)) continue;
            has_other_editor_grid = true;
            break;
        }
        if (!has_other_editor_grid) try self.grid.setWinPos(2, 1000, 0, 0);
    }
}

pub fn handleRpcNotification(self: *Core, arena: std.mem.Allocator, top: []mp.Value) void {
    if (top.len < 3) return;
    if (top[1] != .str or top[2] != .arr) return;

    const method = top[1].str;
    const params = top[2].arr;

    if (std.mem.eql(u8, method, "redraw")) {
        // Detach has been queued but its response boundary has not arrived.
        // These batches were produced by the poisoned UI epoch and must never
        // be applied. During await_attach, redraw belongs to the fresh epoch
        // and is intentionally processed before Neovim serializes the attach
        // response.
        if (self.redraw_recovery_failed.load(.seq_cst) or self.redraw_recovery_state == .await_detach) return;

        // Lock grid_mu to prevent concurrent access from UI thread during redraw.
        // NOTE: All frontend callbacks invoked below (on_vertices_*, on_guifont,
        // on_linespace, on_external_window*, on_ime_off, on_cursor_grid_changed)
        // execute while grid_mu is held. Callbacks MUST NOT call
        // zonvie_core_get_* or other APIs that acquire grid_mu.
        self.grid_mu.lockUncancelable(clock.io());

        // Store current thread ID (to detect re-entrant updateLayoutPx calls
        // from this thread) only AFTER acquiring grid_mu, and clear it
        // before unlocking below — the owner id must never be visible to
        // another thread except while grid_mu is actually held by the
        // thread that set it. Setting it before the lock (or clearing it
        // after unlocking) opens a window where a different thread — e.g.
        // zonvie_core_retry_flush on the UI thread — can read/write this
        // same atomic while this thread is mid-callback (or vice versa),
        // clobbering the id a re-entrant updateLayoutPx call on the OTHER
        // thread depends on and causing it to self-deadlock on grid_mu it
        // already holds.
        self.redraw_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);

        var fctx = flush.FlushCtx{ .core = self };
        var redraw_error: ?anyerror = null;
        redraw.handleRedraw(
            &self.grid,
            &self.hl,
            arena,
            params,
            &self.log,
            &fctx,
            prepareRenderStateForFlush,
            flush.FlushCtx.onFlush,
            &fctx,
            flush.FlushCtx.onGuifont,
            &fctx,
            flush.FlushCtx.onLinespace,
            flush.FlushCtx.onSetTitle,
            flush.FlushCtx.onDefaultColors,
            flush.FlushCtx.onRestart,
            flush.FlushCtx.onConnect,
        ) catch |re| {
            self.log.write("redraw err: {any}\n", .{re});
            redraw_error = re;
        };

        if (redraw_error) |reason| {
            // Do not run UI-extension post-processing and do not present this
            // partial batch. Release grid_mu before enqueueing detach: sendRaw
            // takes the writer lock and session teardown/reset has its own
            // lock ordering.
            self.redraw_thread_id.store(0, .seq_cst);
            self.grid_mu.unlock(clock.io());
            handleRedrawFailure(self, reason);
            return;
        }

        // Per-redraw post-processing notifications. Each one is a thin wrapper
        // over UI-extension state diffing, but they fire callbacks that may run
        // arbitrary frontend code, so individual timing helps explain
        // redraw_batch tail latency. Verbose tier: 4 lines per redraw batch
        // add up during scroll bursts; enable [log] verbose to trace them.
        const log_on_notify = self.log.cb != null and self.log.verbose;

        // Send config parse error on first redraw (Neovim is ready at this point)
        if (!self.config_error_sent) {
            if (self.msg_config.parse_error) |err_msg| {
                flush.sendConfigError(self, err_msg);
            } else {
                self.config_error_sent = true;
            }
        }

        // Handle tabline changes (ext_tabline)
        const t_notify_tabline: i128 = if (log_on_notify) clock.nowNs() else 0;
        self.notifyTablineChanges();
        if (log_on_notify) {
            const dt: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_notify_tabline), 1000));
            self.log.write("[perf] notify_tabline us={d}\n", .{dt});
        }

        var postprocess_error: ?anyerror = null;
        postprocess: {
            // Process pending ext_windows grid resizes (from win_resize events).
            // win_resize is Neovim's request to the UI. The UI decides the actual
            // size and responds with try_resize_grid. Neovim then confirms with grid_resize.
            for (self.grid.pending_grid_resizes.items) |resize| {
                if (!self.known_external_grids.contains(resize.grid_id)) {
                    // NEW grid: Use a reasonable initial size for new external windows.
                    // Neovim's proposed size is based on terminal layout (e.g. height=2)
                    // which is too small for an OS window. Use half the main window.
                    const init_rows = @max(resize.height, self.grid.rows / 2);
                    const init_cols = @max(resize.width, self.grid.cols / 2);
                    self.requestTryResizeGridInternal(resize.grid_id, init_rows, init_cols) catch |err| {
                        postprocess_error = err;
                        break :postprocess;
                    };

                    // Mark grid as pending initial resize. Window creation will be
                    // deferred in notifyExternalWindowChanges until Neovim responds
                    // with grid_resize matching the requested dimensions.
                    self.grid.pending_ext_window_grids.put(self.alloc, resize.grid_id, .{
                        .grid_id = resize.grid_id,
                        .width = init_cols,
                        .height = init_rows,
                    }) catch |err| {
                        postprocess_error = err;
                        break :postprocess;
                    };
                } else {
                    // EXISTING grid: Neovim is requesting a resize (e.g. <C-w>+/-/>/<).
                    // Honor the request by calling try_resize_grid with Neovim's values.
                    self.requestTryResizeGridInternal(resize.grid_id, resize.height, resize.width) catch |err| {
                        postprocess_error = err;
                        break :postprocess;
                    };
                }
            }
            self.grid.pending_grid_resizes.clearRetainingCapacity();

            // Neovim-initiated main grid resize (`:set columns=` / `:set lines=`).
            // Grid 1 normally echoes the size the frontend asked for through
            // updateLayoutPx; a different size means Neovim changed it itself, so
            // ask the frontend to resize its window to match.
            if (self.grid.pending_main_grid_size) |sz| {
                self.grid.pending_main_grid_size = null;
                if (self.last_layout_rows != 0 and self.last_layout_cols != 0 and
                    (sz.rows != self.last_layout_rows or sz.cols != self.last_layout_cols))
                {
                    if (self.cb.on_main_grid_size) |cb| {
                        // last_layout_* is deliberately NOT updated here. The main
                        // grid's NDC viewport is derived from the drawable, so the
                        // vertices Neovim just triggered cover only the cells that
                        // fit the OLD window. Letting the post-resize
                        // updateLayoutPx run its normal try_resize round trip makes
                        // Neovim repaint once the drawable actually matches.
                        self.log.write(
                            "[main_grid_size] neovim-initiated resize rows={d} cols={d}\n",
                            .{ sz.rows, sz.cols },
                        );
                        cb(self.ctx, sz.rows, sz.cols);
                    }
                }
            }

            // Process pending ext_windows layout operations (win_move, win_exchange, etc.)
            // These are deferred to the end of the redraw batch (not immediate) because they
            // depend on grid state that may be updated earlier in the same batch.
            // The frontend callbacks run synchronously here on the core thread.
            for (self.grid.pending_win_ops.items) |op| {
                switch (op.op) {
                    .move => {
                        if (self.cb.on_win_move) |cb| cb(self.ctx, op.grid_id, op.win, op.flags_or_direction);
                    },
                    .exchange => {
                        if (self.cb.on_win_exchange) |cb| cb(self.ctx, op.grid_id, op.win, op.count);
                    },
                    .rotate => {
                        if (self.cb.on_win_rotate) |cb| cb(self.ctx, op.grid_id, op.win, op.flags_or_direction, op.count);
                    },
                    .resize_equal => {
                        if (self.cb.on_win_resize_equal) |cb| cb(self.ctx);
                    },
                }
            }
            self.grid.pending_win_ops.clearRetainingCapacity();
        }

        if (postprocess_error) |reason| {
            self.log.write("redraw post-processing err: {any}\n", .{reason});
            self.redraw_thread_id.store(0, .seq_cst);
            self.grid_mu.unlock(clock.io());
            handleRedrawFailure(self, reason);
            return;
        }

        // Check IME off request (from mode_change event)
        if (self.grid.ime_off_requested) {
            self.grid.ime_off_requested = false;
            if (self.msg_config.input.ime_disable_on_modechange) {
                if (self.cb.on_ime_off) |cb| {
                    cb(self.ctx);
                }
            }
        }

        // default_colors_set triggers an asynchronous config reload after the
        // grid lock is released. hl_group_set was resolved by the pre-flush hook.
        var need_reload_glow_config = false;
        if (self.hl.default_colors_changed) {
            self.hl.default_colors_changed = false;
            // Always re-request glow config on colorscheme change.
            // hl group IDs may have changed, so existing glow_hl_ids could be stale.
            need_reload_glow_config = true;
        }

        // Clear the owner id while STILL holding grid_mu (see the store
        // above): only then unlock, so no other thread can ever observe a
        // stale or cleared owner id while this thread's critical section
        // is still technically in progress.
        self.redraw_thread_id.store(0, .seq_cst);
        self.grid_mu.unlock(clock.io());
        if (need_reload_glow_config) {
            self.requestGlowConfig();
        } else if (self.glow_startup_retries > 0 and
            !self.glow_enabled.load(.acquire) and self.glow_group_names.items.len == 0 and !self.glow_all and
            self.glow_request_msgid.load(.acquire) == 0)
        {
            // Only send if no request already pending (avoid burning retries)
            self.requestGlowConfig();
        }
    } else if (std.mem.eql(u8, method, "zonvie_ime_off")) {
        // Custom RPC notification for IME off (user-invokable)
        if (self.cb.on_ime_off) |cb| {
            cb(self.ctx);
        }
    } else if (std.mem.eql(u8, method, "zonvie_option_as_meta")) {
        // Store the new value atomically; the frontend reads it on each keyDown.
        if (params.len > 0 and params[0] == .str) {
            const val_str = params[0].str;
            const val: u8 = if (std.mem.eql(u8, val_str, "both")) 0 else if (std.mem.eql(u8, val_str, "none")) 1 else if (std.mem.eql(u8, val_str, "only_left")) 2 else if (std.mem.eql(u8, val_str, "only_right")) 3 else return; // unknown value: keep existing setting
            self.option_as_meta.store(val, .release);
        }
    } else if (std.mem.eql(u8, method, "zonvie_mousescroll")) {
        // Rows one wheel event scrolls; see setupMouseScrollReporter. Clamped
        // to what the frontend's lookahead can carry — a pathological
        // 'mousescroll' must not make it hold an unbounded pixel offset.
        if (params.len > 0 and params[0] == .int) {
            const v = params[0].int;
            const clamped: u32 = if (v <= 0) 0 else if (v > 32) 32 else @intCast(v);
            self.mousescroll_ver.store(clamped, .release);
            self.log.write("mousescroll ver={d}\n", .{clamped});
        }
    } else if (std.mem.eql(u8, method, "zonvie_agent_status")) {
        // Custom RPC notification: AI-agent work state for one tabpage.
        // params[0] = { tab, state: Integer 0..4 | 0x80|(1 or 4), title: String }
        //   Low 7 bits: 0=none, 1=idle (agent present, done), 2=working/claude,
        //   3=working/braille, 4=waiting for user input (decision prompt on screen).
        //   Bit 7 (0x80): the reporter detected a completion edge and the
        //   frontend should fire its OS notification now (only set with base
        //   1 or 4). The frontend must render the indicator from the low 7
        //   bits alone and must not edge-detect notifications itself -- a
        //   flagged report may target a tab that isn't currently displaying
        //   the agent's terminal (see setupAgentStatus doc comment).
        // Emitted (debounced) by the auto-injected reporter. Forwarded straight
        // to the frontend, which owns the per-tab indicator + spinner animation.
        // Not coupled to grid/redraw, so a background-tab agent still updates.
        if (params.len > 0 and params[0] == .map) {
            var tab_handle: i64 = 0;
            var have_tab = false;
            var state: u8 = 0;
            var have_state = false;
            var title: []const u8 = "";
            for (params[0].map) |pair| {
                if (pair.key != .str) continue;
                if (std.mem.eql(u8, pair.key.str, "tab")) {
                    if (pair.val == .int) {
                        tab_handle = pair.val.int;
                        have_tab = true;
                    }
                } else if (std.mem.eql(u8, pair.key.str, "state")) {
                    if (pair.val == .int and pair.val.int >= 0 and pair.val.int <= 0x84 and (pair.val.int & 0x7f) <= 4) {
                        state = @intCast(pair.val.int);
                        have_state = true;
                    }
                } else if (std.mem.eql(u8, pair.key.str, "title")) {
                    if (pair.val == .str) title = pair.val.str;
                }
            }
            // Require an explicit, valid state. A notification with only `tab`
            // (state missing or out of range) must NOT fire with state=0, which
            // would erase a working tab's indicator on malformed input.
            if (have_tab and have_state) {
                if (self.cb.on_agent_status) |cb| cb(self.ctx, tab_handle, state, title.ptr, title.len);
            }
        }
    }
}

pub fn runLoop(self: *Core) void {
    // Raise this thread to match the UI thread's QoS. grid_mu (std.Io.Mutex,
    // a futex-based lock with no priority donation on Darwin -- see
    // COMPARE_AND_WAIT vs UL_UNFAIR_LOCK) is held by this thread for the
    // entire handleRedraw duration; without a matching QoS class, a lower-
    // priority core thread contending against a user-interactive main
    // thread can be starved by the scheduler, widening the exact
    // priority-inversion window the try-lock conversions on the input path
    // are meant to narrow. This is a complement to those conversions, not
    // a substitute -- it does not shorten how long grid_mu is held.
    if (comptime builtin.os.tag == .macos) {
        _ = std.c.pthread_set_qos_class_self_np(.USER_INTERACTIVE, 0);
    }
    // DEBUG: Log immediately at runLoop start
    if (self.cb.on_log) |logfn| {
        const msg = "[RUNLOOP] runLoop started!\n";
        logfn(self.ctx, msg.ptr, msg.len);
    }

    const nvim_path = self.nvim_path_owned orelse "nvim";

    // Check if this is a WSL or SSH command
    // WSL command format: "wsl.exe [-d distro] --shell-type login -- nvim --embed"
    // SSH command format: "ssh [-p port] [-i identity] user@host ..." or full path like "C:\...\ssh.exe ..."
    // SSH-ASKPASS format: "ssh-askpass ..." - SSH_ASKPASS already handled auth, skip waiting
    // CMD format: "cmd.exe /c ssh ..." - used on Windows to run SSH via shell
    // Shell format: "/bin/sh -c ..." - used for complex commands (e.g., devcontainer up && exec)
    const is_wsl = std.mem.startsWith(u8, nvim_path, "wsl");
    const is_ssh_askpass = std.mem.startsWith(u8, nvim_path, "ssh-askpass");
    const is_cmd = std.mem.startsWith(u8, nvim_path, "cmd");
    const is_shell = std.mem.startsWith(u8, nvim_path, "/bin/sh") or std.mem.startsWith(u8, nvim_path, "/bin/bash");
    // Check for devcontainer: "devcontainer exec ..." or "devcontainer.cmd exec ..."
    const is_devcontainer = std.mem.startsWith(u8, nvim_path, "devcontainer");
    // Check for SSH: starts with "ssh", contains "ssh.exe", or cmd.exe with ssh
    const contains_ssh_exe = std.mem.indexOf(u8, nvim_path, "ssh.exe") != null;
    const is_ssh = (std.mem.startsWith(u8, nvim_path, "ssh") and !is_ssh_askpass) or
        contains_ssh_exe or
        (is_cmd and std.mem.indexOf(u8, nvim_path, "ssh") != null);

    // Remote modes wrap nvim in an indirection (ssh / devcontainer / wsl /
    // shell / cmd). The listen_addr returned by a `:restart` event lives
    // inside that indirection and is not reachable from the host, so a
    // restart in remote mode falls back to re-spawn instead of socket
    // connect. Pure native sessions (and any future "connect to running
    // nvim" entry point) get the proper transparent reconnect.
    const is_remote_for_restart = is_wsl or is_ssh or is_ssh_askpass or
        is_cmd or is_shell or is_devcontainer;

    // Buffer for parsed arguments
    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;

    if (is_wsl or is_ssh or is_ssh_askpass or is_cmd or is_devcontainer or is_shell) {
        // Parse command string into arguments (split by spaces, handle quotes and escapes)
        var i: usize = 0;
        while (i < nvim_path.len and argc < argv_buf.len) {
            // Skip leading spaces
            while (i < nvim_path.len and nvim_path[i] == ' ') : (i += 1) {}
            if (i >= nvim_path.len) break;

            var arg_start = i;
            var arg_end = i;

            if (nvim_path[i] == '\'' or nvim_path[i] == '"') {
                // Quoted argument - find closing quote (handle escaped quotes)
                const quote_char = nvim_path[i];
                i += 1;
                arg_start = i;
                while (i < nvim_path.len) {
                    if (nvim_path[i] == '\\' and i + 1 < nvim_path.len and nvim_path[i + 1] == quote_char) {
                        // Skip escaped quote (e.g., \" inside "..." or \' inside '...')
                        i += 2;
                    } else if (nvim_path[i] == quote_char) {
                        // Found unescaped closing quote
                        break;
                    } else {
                        i += 1;
                    }
                }
                arg_end = i;
                if (i < nvim_path.len) i += 1; // Skip closing quote
            } else {
                // Unquoted argument - find next space
                while (i < nvim_path.len and nvim_path[i] != ' ') : (i += 1) {}
                arg_end = i;
            }

            if (arg_end > arg_start) {
                const part = nvim_path[arg_start..arg_end];
                // Skip "ssh-askpass" prefix - actual ssh command is next argument
                if (argc == 0 and is_ssh_askpass and std.mem.eql(u8, part, "ssh-askpass")) {
                    // Don't add to argv, just continue to next argument
                    continue;
                }
                argv_buf[argc] = part;
                argc += 1;
            }
        }
        if (is_wsl) {
            self.log.write("WSL mode: parsed {d} arguments\n", .{argc});
        } else if (is_ssh_askpass) {
            self.log.write("SSH-ASKPASS mode: parsed {d} arguments (auth already done)\n", .{argc});
            // Don't set is_ssh_mode - auth is already handled by SSH_ASKPASS
        } else if (is_devcontainer) {
            self.log.write("devcontainer mode: parsed {d} arguments\n", .{argc});
            // Don't set is_ssh_mode - devcontainer doesn't need SSH auth
        } else if (is_shell) {
            self.log.write("shell mode: parsed {d} arguments\n", .{argc});
            // Don't set is_ssh_mode - shell command handles its own execution
        } else {
            self.log.write("SSH mode: parsed {d} arguments\n", .{argc});
            self.is_ssh_mode = true;
        }
    } else {
        // Native: parse command string and insert --embed after first argument
        // e.g., "nvim file.txt" → ["nvim", "--embed", "file.txt"]
        // e.g., "nvim -u /tmp/init.lua +10 file.txt" → ["nvim", "--embed", "-u", "/tmp/init.lua", "+10", "file.txt"]
        var i: usize = 0;
        while (i < nvim_path.len and argc < argv_buf.len - 1) { // -1 to leave room for --embed
            // Skip leading spaces
            while (i < nvim_path.len and nvim_path[i] == ' ') : (i += 1) {}
            if (i >= nvim_path.len) break;

            var arg_start = i;
            var arg_end = i;

            if (nvim_path[i] == '\'' or nvim_path[i] == '"') {
                // Quoted argument - find closing quote (handle escaped quotes)
                const quote_char = nvim_path[i];
                i += 1;
                arg_start = i;
                while (i < nvim_path.len) {
                    if (nvim_path[i] == '\\' and i + 1 < nvim_path.len and nvim_path[i + 1] == quote_char) {
                        // Skip escaped quote
                        i += 2;
                    } else if (nvim_path[i] == quote_char) {
                        // Found unescaped closing quote
                        break;
                    } else {
                        i += 1;
                    }
                }
                arg_end = i;
                if (i < nvim_path.len) i += 1; // Skip closing quote
            } else {
                // Unquoted argument - find next space
                while (i < nvim_path.len and nvim_path[i] != ' ') : (i += 1) {}
                arg_end = i;
            }

            if (arg_end > arg_start) {
                argv_buf[argc] = nvim_path[arg_start..arg_end];
                argc += 1;

                // Insert --embed after first argument (nvim executable)
                if (argc == 1) {
                    argv_buf[argc] = "--embed";
                    argc += 1;
                }
            }
        }

        // If no arguments parsed, fall back to simple path + --embed
        if (argc == 0) {
            argv_buf[0] = nvim_path;
            argv_buf[1] = "--embed";
            argc = 2;
        }

        self.log.write("Native mode: parsed {d} arguments\n", .{argc});
    }

    self.log.write("spawning nvim: {s}\n", .{nvim_path});
    for (argv_buf[0..argc]) |arg| {
        self.log.write("  arg: {s}\n", .{arg});
    }
    self.log.write("[MARKER] before logEnvHints\n", .{});
    logEnvHints(self);
    self.log.write("[MARKER] after logEnvHints\n", .{});

    // === Session loop ===
    //
    // First iteration spawns nvim (or, in the future, opens an initial
    // socket connection — currently not yet a separate entry point).
    // Subsequent iterations are entered only when a `:restart` event
    // queued `restart_pending_addr`. In that case:
    //   - Native mode:   open a socket to listen_addr (transparent reconnect).
    //   - Remote mode:   re-spawn the same argv (listen_addr unreachable).
    //   - Connect failure: same as remote — fall back to re-spawn.
    //
    // Persistent state (grid, hl, atlas, ext UI, layout dimensions) carries
    // across iterations untouched, so the user sees no flicker on `:restart`.
    var ui_attached_overall: bool = false;
    var last_term: ?std.process.Child.Term = null;
    // Set true on any session-fatal failure path that breaks :session
    // without producing a usable last_term. Covers connect failures
    // (remote :connect, connect-only mode, hot-swap fallback skip),
    // spawn failure, ui_attach send failure, transport init failure.
    // The on_exit code path below uses this to override the
    // ui_attached_overall=true → exit 0 default — once a session has
    // attached at least once, a later attach/connect failure would
    // otherwise look like a clean exit to scripts wrapping zonvie.
    var session_failed: bool = false;

    session: while (true) {
        var session_addr: ?[]u8 = null;
        var use_connect: bool = false;
        // Snapshot whether the pending session was queued by `:connect`
        // (hot-swap, old nvim orphaned) vs `:restart` (old nvim dead).
        // Consumed below so a subsequent fall-through to spawn doesn't
        // see stale state.
        var was_connect_hotswap: bool = false;
        if (self.restart_pending_addr) |a| {
            self.restart_pending_addr = null;
            was_connect_hotswap = self.restart_pending_is_connect_hotswap;
            self.restart_pending_is_connect_hotswap = false;
            if (is_remote_for_restart) {
                if (was_connect_hotswap) {
                    // Remote-mode `:connect` hot-swap: the new server's
                    // listen socket lives inside the SSH / WSL /
                    // devcontainer / shell wrapper and is not reachable
                    // from the host, so we can't attach. The old nvim has
                    // already been orphaned by cleanup, so falling through
                    // to spawn the original argv would launch a wholly new
                    // remote session unrelated to the user's editing state
                    // in the orphan. Surface the failure via on_exit
                    // instead.
                    self.log.write("connect: remote-mode :connect cannot reach new server's listen socket and old nvim is orphaned; not spawning surprise replacement; exiting run loop (addr={s})\n", .{a});
                    self.alloc.free(a);
                    session_failed = true;
                    break :session;
                }
                self.log.write("restart: remote mode, re-spawning instead of connecting (addr={s})\n", .{a});
                self.alloc.free(a);
            } else {
                session_addr = a;
                use_connect = true;
            }
        }
        defer if (session_addr) |a| self.alloc.free(a);

        // === Set up transport ===
        var have_child: bool = false;
        var child: std.process.Child = undefined;
        var cwd_owner: CwdOwner = .{};
        defer cwd_owner.close();

        if (use_connect) {
            const conn_opt: ?rpc_transport.Stream = rpc_transport.connectListenAddr(self.alloc, session_addr.?) catch |e| blk: {
                self.log.write("connect to {s} failed: {any}; falling back to re-spawn\n", .{ session_addr.?, e });
                break :blk null;
            };
            if (conn_opt) |conn| {
                self.stdin_close_mu.lockUncancelable(clock.io());
                self.transport_kind = .socket;
                self.stdin_file = conn;
                self.stdout_file = conn; // alias of the same fd / pipe wrapper
                self.stderr_file = null;
                // For Windows named pipes the Stream wraps a heap-allocated
                // *WindowsOverlappedPipe. Save the owning pointer so we can
                // destroy() the wrapper *after* the writer/stderr threads
                // have been joined — Stream.close() only fires CancelIoEx
                // on the pipe HANDLE (no HANDLE close yet) so blocked
                // GetOverlappedResult calls return without their HANDLE
                // references being closed mid-wait. The pipe HANDLE, the
                // event HANDLEs, and the wrapper memory are all released
                // together by destroy(). Without this separate ownership
                // pointer, the alias-null in stop()/cleanupSession would
                // drop our only reference and the wrapper would leak.
                self.session_pipe = switch (conn) {
                    .win_pipe => |p| p,
                    .file => null,
                };
                self.stdin_close_mu.unlock(clock.io());
                self.log.write("connect: established socket session to {s}\n", .{session_addr.?});
            } else if (nvim_path.len == 0) {
                // Connect-only mode (started via zonvie_core_start_connect): no
                // argv to fall back to. Exit cleanly without spawning a
                // surprise local nvim.
                self.log.write("connect: no spawn fallback (connect-only mode); exiting run loop\n", .{});
                session_failed = true;
                break :session;
            } else if (was_connect_hotswap) {
                // `:connect` hot-swap: the old nvim is already orphaned
                // (kept alive headless on its own listen socket — the user
                // can still reach it manually). Falling through to spawn
                // the original argv would open a brand-new local nvim
                // session that is unrelated to the user's editing state in
                // the orphan, leaving them with TWO disconnected sessions.
                // Exit cleanly so the frontend (via on_exit) can surface
                // the failure instead.
                self.log.write("connect: :connect hot-swap connect failed and old nvim is orphaned; not spawning surprise local fallback; exiting run loop\n", .{});
                session_failed = true;
                break :session;
            } else {
                use_connect = false; // fall through to spawn
            }
        }

        if (!use_connect) {
            var child_cwd: std.process.Child.Cwd = .inherit;
            if (!self.inherit_cwd) {
                cwd_owner.openPreferred(self.alloc, &self.log);
                child_cwd = cwd_owner.childCwd();
            } else {
                self.log.write("inherit_cwd=true; child inherits parent cwd\n", .{});
            }

            const has_slash = (std.mem.indexOfScalar(u8, nvim_path, '/') != null) or
                (std.mem.indexOfScalar(u8, nvim_path, '\\') != null);
            self.log.write("expand_arg0: has_slash={}, mode={s}\n", .{ has_slash, if (has_slash) "no_expand" else "expand" });

            self.log.write("about to spawn...\n", .{});
            if (self.cb.on_log) |logfn| {
                const msg1 = "[DIRECT] calling std.process.spawn() now\n";
                logfn(self.ctx, msg1.ptr, msg1.len);
            }
            const spawn_start_ns = clock.nowNs();
            // Inherit the LIVE environment (incl. frontend setenv like
            // SSH_ASKPASS) instead of the Io's init-time snapshot. See
            // liveEnvironMap. Null on Windows / OOM → falls back to the Io
            // environ, which is correct for native spawns.
            var child_env = liveEnvironMap(self.alloc);
            defer if (child_env) |*m| m.deinit();
            child = std.process.spawn(clock.io(), .{
                .argv = argv_buf[0..argc],
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .pipe,
                .create_no_window = true,
                .cwd = child_cwd,
                .expand_arg0 = if (has_slash) .no_expand else .expand,
                .environ_map = if (child_env) |*m| m else null,
            }) catch |e| {
                self.log.write("spawn failed: {any}\n", .{e});
                if (self.cb.on_log) |logfn| {
                    const msg_err = "[DIRECT] spawn error occurred\n";
                    logfn(self.ctx, msg_err.ptr, msg_err.len);
                }
                session_failed = true;
                break :session;
            };
            const spawn_end_ns = clock.nowNs();
            const spawn_ms = @divTrunc(spawn_end_ns - spawn_start_ns, 1_000_000);
            if (self.cb.on_log) |logfn| {
                const msg2 = "[DIRECT] child.spawn() returned successfully\n";
                logfn(self.ctx, msg2.ptr, msg2.len);
            }
            self.log.write("[TIMING] nvim spawn: {d}ms\n", .{spawn_ms});
            self.log.write("spawn returned ok, pid={any}\n", .{child.id});

            self.publishChildHandle(child.id);
            self.stdin_close_mu.lockUncancelable(clock.io());
            self.transport_kind = .pipes;
            self.stdin_file = if (child.stdin) |f| rpc_transport.Stream.fromFile(f) else null;
            self.stdout_file = if (child.stdout) |f| rpc_transport.Stream.fromFile(f) else null;
            self.stderr_file = if (child.stderr) |f| rpc_transport.Stream.fromFile(f) else null;
            self.stdin_close_mu.unlock(clock.io());

            // OWNERSHIP TRANSFER: keep handles in Core; prevent Child from closing them.
            child.stdin = null;
            child.stdout = null;
            child.stderr = null;

            have_child = true;

            if (self.stderr_file) |ef| {
                // Allocate the pump state on the heap so it can outlive
                // Core (orphan path). Pump thread frees it on exit.
                //
                // Use std.heap.c_allocator instead of self.alloc here:
                // an orphan-detached pump can still be running when
                // zonvie_core_destroy calls box.gpa.deinit(), at which
                // point self.alloc would be a dead allocator interface.
                // c_allocator is process-lifetime, so the pump's later
                // self.alloc.destroy(self) is always safe.
                const pump_alloc = std.heap.c_allocator;
                const pump = pump_alloc.create(StderrPump) catch null;
                if (pump) |p| {
                    p.* = .{
                        .alloc = pump_alloc,
                        .f = ef,
                        .mu = .init,
                        .core_users_done = .init,
                        .core = self,
                        .active_core_users = 0,
                        .cleanup_decided = false,
                        // refcount = 2 from the start: one for Core
                        // (kept via self.stderr_pump until cleanup
                        // calls release), one for the pump thread
                        // (released by run()'s defer). Pre-set so the
                        // thread can't observe a stale 0.
                        .refcount = std.atomic.Value(u32).init(2),
                    };
                    self.stderr_pump = p;
                    self.stderr_thread = std.Thread.spawn(.{}, StderrPump.run, .{p}) catch blk: {
                        // Spawn failed: thread never started so it
                        // never took its ref. We are the only holder;
                        // free the struct and close the fd directly,
                        // no need to go through release().
                        p.f.close();
                        pump_alloc.destroy(p);
                        self.stderr_pump = null;
                        break :blk null;
                    };
                } else {
                    // Allocation failed: nothing else owns this fd
                    // (child.stderr is already null after the ownership
                    // transfer above), so close it here. cleanupSession
                    // assumes the pump owns the fd and would only null
                    // self.stderr_file without closing.
                    ef.close();
                }
                // Ownership of stderr_file has been transferred:
                //   - alloc + spawn ok: pump owns; freed by run()'s defer.
                //   - spawn failed: catch above closed and freed pump.
                //   - alloc failed: closed in the else branch above.
                // In all cases Core no longer holds the fd.
                self.stderr_file = null;
            }

            if (builtin.os.tag != .windows) {
                // Reserve the waitpid owner before admitting the session. It
                // remains idle until cleanup either transfers a preserved
                // child or releases it without one.
                const reaper_alloc = std.heap.c_allocator;
                const reaper = reaper_alloc.create(ChildReaper) catch null;
                if (reaper) |r| {
                    r.* = .{
                        .alloc = reaper_alloc,
                        .mu = .init,
                        .decision_ready = .init,
                        .decided = false,
                        .child = null,
                        .refcount = std.atomic.Value(u32).init(2),
                        .reaped = std.atomic.Value(bool).init(false),
                    };
                    self.child_reaper = r;
                    self.child_reaper_thread = std.Thread.spawn(.{
                        .stack_size = 128 * 1024,
                        .allocator = reaper_alloc,
                    }, ChildReaper.run, .{r}) catch blk: {
                        reaper_alloc.destroy(r);
                        self.child_reaper = null;
                        break :blk null;
                    };
                }
            }

            // Neither stderr draining nor waitpid ownership may be acquired
            // lazily in cleanup, where allocation failure could block the
            // child or leave a zombie.
            const reaper_unavailable = builtin.os.tag != .windows and
                (self.child_reaper == null or self.child_reaper_thread == null);
            if (self.stderr_pump == null or self.stderr_thread == null or reaper_unavailable) {
                self.log.write("FATAL: spawned-session helper unavailable; terminating child\n", .{});
                _ = cleanupSession(self, &child, have_child, true, false, false);
                if (!self.stop_flag.load(.seq_cst)) session_failed = true;
                break :session;
            }

            // SSH mode defers writer thread until after authentication completes.
            if (!self.is_ssh_mode) {
                if (!self.startWriterThread()) {
                    _ = cleanupSession(self, &child, have_child, true, false, false);
                    if (!self.stop_flag.load(.seq_cst)) session_failed = true;
                    break :session;
                }
            }

            if (self.is_ssh_mode) {
                self.log.write("SSH mode: prompting for password immediately...\n", .{});
                self.ssh_auth_pending.store(true, .seq_cst);
                std.Io.sleep(clock.io(), .{ .nanoseconds = @intCast(200 * std.time.ns_per_ms) }, .awake) catch {};

                if (self.cb.on_ssh_auth_prompt) |cb| {
                    cb(self.ctx, "SSH Password:", 13);
                    self.log.write("SSH mode: waiting for user to enter password...\n", .{});
                    var waited_ms: u32 = 0;
                    const timeout_ms: u32 = 60000;
                    const poll_ms: u32 = 100;

                    while (waited_ms < timeout_ms and !self.stop_flag.load(.seq_cst)) {
                        if (self.ssh_auth_done.load(.seq_cst)) {
                            self.log.write("SSH mode: password sent, waiting for connection...\n", .{});
                            std.Io.sleep(clock.io(), .{ .nanoseconds = @intCast(2000 * std.time.ns_per_ms) }, .awake) catch {};
                            break;
                        }
                        std.Io.sleep(clock.io(), .{ .nanoseconds = @intCast(poll_ms * std.time.ns_per_ms) }, .awake) catch {};
                        waited_ms += poll_ms;
                    }

                    if (waited_ms >= timeout_ms) {
                        self.log.write("SSH mode: authentication timeout\n", .{});
                    }
                } else {
                    self.log.write("SSH mode: no callback registered\n", .{});
                }

                self.ssh_auth_pending.store(false, .seq_cst);

                if (self.stop_flag.load(.seq_cst)) {
                    self.log.write("SSH mode: stopped by user\n", .{});
                    _ = cleanupSession(self, &child, have_child, false, false, false);
                    break :session;
                }
                if (!self.startWriterThread()) {
                    _ = cleanupSession(self, &child, have_child, true, false, false);
                    session_failed = true;
                    break :session;
                }
            }
        } else {
            // Connect mode has no child process; the writer thread can
            // start immediately (no SSH auth in this path).
            if (!self.startWriterThread()) {
                _ = cleanupSession(self, &child, have_child, true, false, false);
                if (!self.stop_flag.load(.seq_cst)) session_failed = true;
                break :session;
            }
        }

        var ui_attached: bool = false;

        // Block until layout is ready (set by notifyLayoutReady on first
        // start). For restart iterations ui_attach_ready is already true,
        // so this falls through immediately.
        {
            self.ui_attach_mutex.lockUncancelable(clock.io());
            defer self.ui_attach_mutex.unlock(clock.io());
            while (!self.ui_attach_ready) {
                if (self.stop_flag.load(.seq_cst)) break;
                self.ui_attach_cond.waitUncancelable(clock.io(), &self.ui_attach_mutex);
            }
        }

        if (self.stop_flag.load(.seq_cst)) {
            _ = cleanupSession(self, &child, have_child, false, false, false);
            break :session;
        }

        self.log.write("[rpc] layout ready: rows={d} cols={d}, sending ui_attach\n", .{ self.ui_attach_rows, self.ui_attach_cols });
        self.requestSetClientInfo() catch |e| self.log.write("send set_client_info failed: {any}\n", .{e});

        // If config.toml [font] family is set, push it to nvim's `guifont`
        // BEFORE ui_attach. Setting it afterwards lands mid-redraw: nvim emits
        // an option_set carrying its default guifont during its initial paint,
        // then a second one once it processes ours. That second paint
        // round-trip was observed briefly dropping the statusline text on
        // Windows at startup; resizing the window forced a full re-seed that
        // restored it. The ordering itself is not platform-specific.
        if (self.msg_config.font.family_explicit) {
            var guifont_buf: [256]u8 = undefined;
            const guifont_str = std.fmt.bufPrint(&guifont_buf, "{s}:h{d}", .{
                self.msg_config.font.family,
                self.msg_config.font.size,
            }) catch null;
            if (guifont_str) |val| {
                self.requestSetOptionValue("guifont", val) catch |e|
                    self.log.write("pre-attach set guifont failed: {any}\n", .{e});
            }
        }

        // Serialize attach publication with latest-wins resize state. A UI
        // resize that arrives before this lock becomes pending and is drained
        // below; one that arrives after waits until attach+drain complete.
        var attach_failed = false;
        {
            self.pending_resize_mu.lockUncancelable(clock.io());
            defer self.pending_resize_mu.unlock(clock.io());
            // A resize successfully queued to the previous session can be
            // discarded during reconnect cleanup. Attach the new session at
            // the retained latest desired size, making publication independent
            // of the old writer queue's delivery epoch.
            const attach_rows = if (self.pending_resize_valid)
                self.pending_resize_rows
            else if (self.desired_resize_rows != 0)
                self.desired_resize_rows
            else
                self.ui_attach_rows;
            const attach_cols = if (self.pending_resize_valid)
                self.pending_resize_cols
            else if (self.desired_resize_cols != 0)
                self.desired_resize_cols
            else
                self.ui_attach_cols;
            self.requestUiAttach(attach_rows, attach_cols) catch |e| {
                self.log.write("ui_attach send failed: {any}\n", .{e});
                attach_failed = true;
            };
            if (!attach_failed) {
                ui_attached = true;
                ui_attached_overall = true;
                self.ui_attached.store(true, .seq_cst);
                self.ui_attach_rows = attach_rows;
                self.ui_attach_cols = attach_cols;
                self.pending_resize_valid = false;
                self.pending_resize_sequence = 0;
                self.flushPendingUiStateLocked();
                self.log.write("ui_attach published latest layout rows={d} cols={d}\n", .{ attach_rows, attach_cols });
            }
        }
        if (attach_failed) {
            _ = cleanupSession(self, &child, have_child, true, false, false);
            session_failed = true;
            break :session;
        }
        // Discover our channel_id via vim.api.nvim_list_chans() and install
        // the clipboard provider hooks.
        setupClipboard(self);

        // Install the AI-agent tab-status reporter (zero user-side config).
        setupAgentStatus(self);

        // Report 'mousescroll' so the trackpad path knows how many rows one
        // wheel event is worth. No-op off macOS (see the function).
        setupMouseScrollReporter(self);

        if (self.stdout_file == null) {
            self.log.write("read transport is null\n", .{});
            _ = cleanupSession(self, &child, have_child, true, false, false);
            session_failed = true;
            break :session;
        }

        var fr = FrameReader.init(self.alloc, self.stdout_file.?) catch |e| {
            self.log.write("FrameReader init failed: {any}\n", .{e});
            _ = cleanupSession(self, &child, have_child, true, false, false);
            session_failed = true;
            break :session;
        };
        defer fr.deinit();

        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();

        // Tracks how the inner loop exited:
        //   false = natural EOF / read error / stop_flag (local restart
        //           takes this path — nvim is exiting on its own)
        //   true  = early break because a remote-mode restart/connect
        //           is queued and the wrapper stdio will never EOF
        // Passed to cleanupSession as `kill_on_restart_pending`.
        var remote_restart_break: bool = false;

        // Inner reader loop — same for both transports. An earlier iteration
        // experimented with a zero-copy streaming decoder here. It lost this
        // path by 1.24x-1.94x at building Value trees, which is a real
        // measurement; the separate bench meant to show its zero-allocation
        // cell writes paying off never actually wrote a cell, so that half
        // proved nothing. The machinery was removed rather than kept as an
        // unwired reference. See DEVELOPMENT.md, "Speeding up grid_line
        // decoding", before attempting it again.
        outer: while (!self.stop_flag.load(.seq_cst)) {
            var root: mp.Value = undefined;
            const log_on_msg = self.log.cb != null;
            // Separate accounting: decode_ns counts CPU time inside mp.decode
            // (across all attempts that returned EndOfStream); io_wait_ns
            // counts wall time blocked on fr.fill() waiting for nvim. Earlier
            // implementation wall-timed the whole loop and reported it as
            // "decode" — that was misleading because most of it was I/O wait.
            var decode_ns: i128 = 0;
            var io_wait_ns: i128 = 0;
            while (true) {
                _ = arena_state.reset(.retain_capacity);
                const arena_once = arena_state.allocator();

                var sr = FrameSliceReader{ .data = fr.view() };
                const t_dec: i128 = if (log_on_msg) clock.nowNs() else 0;
                const dec_res = mp.decode(arena_once, &sr);
                if (log_on_msg) decode_ns += clock.nowNs() - t_dec;
                if (dec_res) |v| {
                    fr.consume(sr.i);
                    root = v;
                    break;
                } else |e| {
                    if (e == error.EndOfStream) {
                        const t_io: i128 = if (log_on_msg) clock.nowNs() else 0;
                        const fill_res = fr.fill();
                        if (log_on_msg) io_wait_ns += clock.nowNs() - t_io;
                        const n = fill_res catch |fe| {
                            self.log.write("pipe read err: {any}\n", .{fe});
                            handleRpcStreamFailure(self, fe);
                            break :outer;
                        };
                        if (n == 0) {
                            self.log.write("decode err: EndOfStream (nvim stdout closed)\n", .{});
                            break :outer;
                        }
                        continue;
                    }
                    self.log.write("decode err: {any}\n", .{e});
                    handleRpcStreamFailure(self, e);
                    break :outer;
                }
            }

            const arena = arena_state.allocator();
            if (root != .arr or root.arr.len < 1) continue;
            const top = root.arr;
            if (top[0] != .int) continue;

            const t = top[0].int;
            if (t == 0) {
                handleRpcRequest(self, arena, top);
                continue;
            }
            if (t == 1) {
                handleRpcResponse(self, top);
                if (self.redraw_recovery_failed.load(.seq_cst)) break :outer;
                continue;
            }
            if (t == 2) {
                const t_dispatch_start: i128 = if (log_on_msg) clock.nowNs() else 0;
                handleRpcNotification(self, arena, top);
                if (log_on_msg) {
                    const dispatch_us: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_dispatch_start), 1000));
                    const decode_us: i64 = @intCast(@divTrunc(@max(@as(i128, 0), decode_ns), 1000));
                    const io_wait_us: i64 = @intCast(@divTrunc(@max(@as(i128, 0), io_wait_ns), 1000));
                    // Only the method string is interesting here; pull it from
                    // top[1] (already validated as .str inside the dispatcher
                    // for the redraw path, but we re-check defensively).
                    const method_for_log: []const u8 = if (top.len >= 2 and top[1] == .str) top[1].str else "?";
                    self.log.write(
                        "[perf] rpc_msg method={s} decode_us={d} io_wait_us={d} dispatch_us={d}\n",
                        .{ method_for_log, decode_us, io_wait_us, dispatch_us },
                    );
                }
                if (self.redraw_recovery_failed.load(.seq_cst)) break :outer;
                // If the notification queued a restart/connect, decide
                // whether to break the inner loop NOW or wait for the
                // natural channel close.
                //
                // Remote modes (SSH / WSL / devcontainer / cmd / shell):
                // the new nvim inherits stdio from the wrapper which
                // never EOFs, so we MUST break here — otherwise we'd be
                // stuck reading forever. cleanupSession will then kill
                // the wrapper to unblock wait().
                //
                // Local spawn: nvim is in the middle of its own clean
                // shutdown (channel close + process exit). Breaking
                // here would force cleanupSession to kill nvim mid-
                // shutdown, racing with shada/viminfo flush, swap file
                // deletion, etc. Instead, fall through and let the
                // inner loop see the natural EOF (decode err path
                // above), which breaks out cleanly. The kill in
                // cleanupSession is then a true no-op on the already-
                // exited child.
                if (self.restart_pending_addr != null) {
                    if (is_remote_for_restart) {
                        self.log.write("inner loop: restart/connect queued (remote); breaking immediately\n", .{});
                        remote_restart_break = true;
                        break :outer;
                    }
                    self.log.write("inner loop: restart/connect queued (local); waiting for natural EOF\n", .{});
                }
                continue;
            }
        }

        // === Session cleanup ===
        // Natural inner-loop exit. cleanupSession's kill conditions cover
        // stop_flag (user stop) automatically, so we don't force-kill
        // here. `kill_on_restart_pending = remote_restart_break` lets
        // remote-mode restarts kill the wrapper (whose stdio never EOFs)
        // while local-mode restarts skip the kill so nvim can finish
        // its own clean shutdown — channel close (EOF) is just one of
        // the last steps in nvim's exit, not the end. Propagate the
        // term so on_exit can compute the right exit code.
        const redraw_recovery_failed = self.redraw_recovery_failed.load(.seq_cst);
        const preserve_recovery_child = redraw_recovery_failed and
            !self.stop_flag.load(.seq_cst);
        self.log.write("session loop: invoking cleanupSession (remote_restart_break={any}, redraw_recovery_failed={any})\n", .{ remote_restart_break, redraw_recovery_failed });
        if (cleanupSession(self, &child, have_child, false, remote_restart_break, preserve_recovery_child)) |t| last_term = t;
        if (redraw_recovery_failed) session_failed = true;
        self.log.write("session loop: cleanupSession returned\n", .{});

        // === Decide next iteration ===
        if (self.stop_flag.load(.seq_cst)) {
            // App-side stop() observed; do not fire on_exit, do not loop.
            self.log.write("session loop: stop_flag set after cleanup; returning\n", .{});
            return;
        }

        if (self.restart_pending_addr != null) {
            // Restart/connect was queued during this session. Reset
            // session-scoped state and loop back; the next iteration uses
            // the connect path (or re-spawn fallback for remote modes).
            // Consume the connect-keeps-alive flag now that the orphan
            // (if any) has been dropped — the next session must not
            // inherit it.
            self.log.write("session loop: restart_pending; entering resetSessionState\n", .{});
            self.connect_keeps_child_alive = false;
            self.resetSessionState();
            self.log.write("session loop: resetSessionState returned\n", .{});
            if (self.stop_flag.load(.seq_cst)) return;
            self.log.write("session loop: continuing to next iteration\n", .{});
            continue :session;
        }

        // Natural exit: nvim closed the channel without queueing a restart.
        self.log.write("session loop: no restart pending; breaking out\n", .{});
        break :session;
    }

    // === After-loop: fire on_exit ===
    // Suppressed only when stop() was already invoked (user-driven shutdown:
    // window close, app quit). For all other paths — including pre-attach
    // failures like connect-only socket-not-found, spawn failure, ui_attach
    // send failure, FrameReader init failure — we still fire on_exit so the
    // frontend can tear down its window instead of leaving a blank shell.
    if (!self.stop_flag.load(.seq_cst)) {
        if (self.cb.on_exit) |f| {
            // Convert Term to exit code:
            //   - session_failed (any session-fatal break path that is
            //     NOT a clean child exit): 1. Checked first so a hot-
            //     swap connect failure on an already-attached session
            //     does not look like a clean exit just because
            //     ui_attached_overall is true.
            //   - Exited: use exit code directly
            //   - Signal: 128 + signal number (Unix convention)
            //   - Stopped/Unknown: return 1 (generic error)
            //   - Natural exit in connect mode (no Term, ui attached): 0
            //   - Pre-attach failure (no Term, never attached): 1
            const exit_code: i32 = if (session_failed)
                1
            else if (last_term) |t| switch (t) {
                .exited => |code| @intCast(code),
                .signal => |sig| 128 + @as(i32, @intCast(@intFromEnum(sig))),
                .stopped, .unknown => 1,
            } else if (ui_attached_overall) 0 else 1;
            self.log.write("calling on_exit with code: {d}\n", .{exit_code});
            f(self.ctx, exit_code);
        }
    }
}

/// Tear down the current RPC session: stop the writer thread, close the
/// transport (with socket-alias handling), reap the child (if any), and
/// join the stderr pump. Safe to call from any session-exit path — both
/// the natural inner-loop exit and the early-exit failure paths
/// (ui_attach failure, FrameReader init failure, stop during ssh-auth,
/// etc.). Safe to call when have_child is false.
///
/// `force_kill_child`: when true, unconditionally kill the child before
/// wait(). Used by early-exit failure paths that do not set stop_flag /
/// restart_pending_addr but still need the child to terminate promptly
/// so wait() does not block (notably SSH / devcontainer / WSL where the
/// wrapper holds stdio open until killed).
///
/// `kill_on_restart_pending`: when true, kill the child if a restart /
/// connect is queued. True for the remote-mode inner-loop early-break
/// path (SSH / WSL / devcontainer / cmd / shell), where the wrapper
/// holds stdio open and child.wait() would block forever without an
/// explicit kill. False for the local-spawn natural-EOF path, where
/// nvim closed its channel while in the middle of its own clean
/// shutdown — child.wait() will reap shortly on its own. Killing in
/// the local case truncates nvim's shutdown work (shada / viminfo
/// flush, swap file deletion, etc.) and violates the Neovim restart
/// UI event contract: the UI must wait for channel close + natural
/// process exit, not force-terminate the old server.
///
/// `preserve_child`: when true, close this session's transport but neither
/// kill nor synchronously wait for its child. Redraw recovery uses this for
/// failures such as allocator exhaustion: terminating an embedded Neovim for
/// a GUI recovery failure could destroy unsaved editing state. POSIX reaps the
/// child asynchronously after it reacts to transport EOF; Windows drops only
/// this process's handles.
///
/// Returns the child's exit term, or null if not available (no child,
/// orphaned for a `:connect` hot-swap, or wait() failed). The caller
/// decides whether to propagate the term to `last_term` for on_exit's
/// exit-code computation.
fn cleanupSession(
    self: *Core,
    child: *std.process.Child,
    have_child: bool,
    force_kill_child: bool,
    kill_on_restart_pending: bool,
    preserve_child: bool,
) ?std.process.Child.Term {
    self.log.write("cleanupSession: enter (have_child={any} force_kill={any} kill_on_restart_pending={any} preserve_child={any} restart_pending={any} connect_keeps_child_alive={any})\n", .{
        have_child,
        force_kill_child,
        kill_on_restart_pending,
        preserve_child,
        self.restart_pending_addr != null,
        self.connect_keeps_child_alive,
    });
    // A `:connect` hot-swap leaves the old nvim alive headless. Recovery
    // failure also avoids killing the child, but transport EOF lets an embed
    // child perform its own shutdown. Neither path can synchronously wait.
    var orphan_child = self.connect_keeps_child_alive or preserve_child;
    const want_kill = have_child and !orphan_child and (force_kill_child or self.stop_flag.load(.seq_cst) or
        (kill_on_restart_pending and self.restart_pending_addr != null));

    // A published child always belongs to a pipe session. Kill it without an
    // unsynchronized transport_kind read before waiting for teardown
    // serialization; this also wakes a concurrent stop() joining its writer.
    if (want_kill) self.requestChildTermination();

    // Serialize the complete writer/raw-resource ownership transition with
    // stopTeardownOwned. Lock order is stdin_close_mu -> write_queue_mu.
    self.stdin_close_mu.lockUncancelable(clock.io());
    const transport_kind = self.transport_kind;
    var wt: ?std.Thread = null;
    self.write_queue_mu.lockUncancelable(clock.io());
    self.write_queue_closed = true;
    wt = self.writer_thread;
    self.writer_thread = null;
    self.write_queue_cond.signal(clock.io());
    self.write_queue_mu.unlock(clock.io());
    const wt_present = wt != null;

    const stdin = self.stdin_file;
    self.cancelWriterIo(wt, stdin, transport_kind);
    if (stdin) |f| f.close();
    self.stdin_file = null;
    if (transport_kind == .socket) self.stdout_file = null;
    self.stdin_close_mu.unlock(clock.io());
    self.log.write("cleanupSession: writer queue closed (wt_present={any})\n", .{wt_present});
    if (wt_present) self.log.write("cleanupSession: writer thread joined\n", .{});
    self.log.write("cleanupSession: stdin closed\n", .{});

    var session_term: ?std.process.Child.Term = null;
    if (have_child) {
        // Withdraw the shared PID/HANDLE before any path below can reap the
        // process or close its handle. A concurrent stop either signals it
        // before this point or observes null; it can never signal a recycled
        // PID/HANDLE after Child.wait()/kill().
        self.claimChildHandleForCleanup();
        if (orphan_child) {
            self.log.write("preserving child without forced termination (pid={any}, connect_hotswap={any}, recovery_failure={any})\n", .{
                child.id,
                self.connect_keeps_child_alive,
                preserve_child,
            });
            // On Windows std.process.Child.Id is a HANDLE and there is
            // also a thread_handle for the main thread. Normally
            // child.wait() closes both, but the orphan path skips
            // wait() (the headless nvim never exits in the foreground
            // case, so wait would block). Close them explicitly so
            // repeated :connect hot-swaps don't leak HANDLEs. The
            // process keeps running because HANDLEs are merely kernel-
            // object references, not the process itself.
            //
            // On POSIX the prestarted reaper adopts the Child and waits
            // independently of stderr EOF. Spawned sessions are rejected
            // before attach when that service is unavailable, so this cleanup
            // path allocates nothing. child.stdin/stdout/stderr were nulled on
            // ownership transfer, so wait() cannot close pump-owned handles.
            if (builtin.os.tag == .windows) {
                if (child.id) |h| std.os.windows.CloseHandle(h);
                std.os.windows.CloseHandle(child.thread_handle);
            } else {
                const reaper_adopted = if (self.child_reaper) |reaper| reaper.adopt(child.*) else false;
                if (!reaper_adopted) {
                    // This is an invariant violation, not a recoverable
                    // allocation path. Reap synchronously via Child.kill()
                    // rather than dropping the only process owner.
                    self.log.write("FATAL: child reaper refused ownership; terminating child (pid={any})\n", .{child.id});
                    child.kill(clock.io());
                    session_term = .{ .signal = .TERM };
                    orphan_child = false;
                }
            }
        } else {
            // Kill conditions:
            //   - User stop (stop_flag): terminate promptly so we don't
            //     block on wait().
            //   - force_kill_child: early-exit failure paths haven't set
            //     stop_flag, but still need the child reaped without
            //     blocking on wait().
            //   - restart/connect pending AND kill_on_restart_pending:
            //     remote modes (SSH / WSL / devcontainer / cmd / shell)
            //     where the wrapper holds stdio open after nvim exits.
            //     Without an explicit kill, wait() blocks forever on
            //     the wrapper. The local-spawn natural-EOF path passes
            //     kill_on_restart_pending=false so we let nvim finish
            //     its shutdown (shada / viminfo / swap file cleanup)
            //     and reap via wait() — EOF is channel close, not
            //     process exit, so racing a kill against the still-in-
            //     progress teardown would truncate nvim's work.
            if (want_kill) {
                self.log.write("cleanupSession: killing child (pid={any})\n", .{child.id});
                // Zig 0.16: Child.kill(io) forcibly terminates AND reaps in a
                // single uncancelable call, leaving child.id == null. wait()
                // opens with assert(child.id != null), so it MUST NOT be called
                // after kill(). Synthesize the Term the prior (kill + wait)
                // sequence reported so on_exit's exit-code mapping is unchanged
                // per platform: POSIX kill sends SIGTERM (Threaded.childKillPosix)
                // -> Term.signal -> 128+SIGTERM; Windows kill terminates with
                // exit code 1 (Threaded.childKillWindows) -> Term.exited -> 1.
                child.kill(clock.io());
                session_term = if (builtin.os.tag == .windows) .{ .exited = 1 } else .{ .signal = .TERM };
            } else {
                self.log.write("cleanupSession: waiting for child (pid={any})\n", .{child.id});
                session_term = child.wait(clock.io()) catch |e| blk: {
                    self.log.write("wait err: {any}\n", .{e});
                    break :blk null;
                };
            }
            if (session_term) |t| self.log.write("nvim terminated: {any}\n", .{t});
        }
    }

    // Finalize the POSIX wait service independently of the stderr pump. An
    // adopted child can outlive this session, so detach its already-running
    // waiter; all other paths wake and join the idle service synchronously.
    if (orphan_child and self.child_reaper != null) {
        if (self.child_reaper_thread) |reaper_thread| {
            reaper_thread.detach();
            self.child_reaper_thread = null;
        }
        if (self.child_reaper) |reaper| {
            reaper.release();
            self.child_reaper = null;
        }
    } else {
        if (self.child_reaper) |reaper| reaper.finishWithoutChild();
        if (self.child_reaper_thread) |reaper_thread| reaper_thread.join();
        self.child_reaper_thread = null;
        if (self.child_reaper) |reaper| reaper.release();
        self.child_reaper = null;
    }

    // Close any remaining transport handles. stderr_file is intentionally
    // NOT closed here — its fd is owned by pumpStderr (which defer-closes
    // on exit), so closing from this thread risks fd reuse if the pump's
    // blocked read syscall hasn't yet observed EOF and the fd number is
    // recycled by the next open() in our process. Just null the alias.
    if (self.stdout_file) |f| {
        self.log.write("cleanupSession: closing stdout\n", .{});
        f.close();
        self.stdout_file = null;
        self.log.write("cleanupSession: stdout closed\n", .{});
    }
    self.stderr_file = null;

    // An EOF'd pump waits for this ownership decision before releasing its
    // thread. Orphan reaping is handled independently above.
    if (self.stderr_pump) |pump| pump.finishCleanupDecision();

    // Reap the stderr pump.
    //   - Final-shutdown path (no restart pending, no orphan): child
    //     died, its stderr writer closed, our pump read returned 0,
    //     the pump thread is exiting (or already exited). join()
    //     completes promptly.
    //   - Orphan path (`:connect` hot-swap): the old nvim is still
    //     running and holds the stderr writer open, so the pump is
    //     stuck in a blocking read that close() on the read end does
    //     NOT wake on POSIX. Joining would hang the run loop and
    //     prevent attaching to the new server. Detach instead.
    //   - Restart-pending path (`:restart`): even though the old
    //     nvim has exited, the headless successor it spawned to host
    //     the new session may have inherited a stray write reference
    //     to our stderr pipe across the libuv fork (uv_spawn with
    //     UV_IGNORE on stderr replaces the child's fd 2 with
    //     /dev/null but does NOT close OTHER inherited fds without
    //     CLOEXEC; if old nvim's libuv held a dup of fd 2 elsewhere,
    //     the successor keeps our pipe writer open). The successor
    //     outlives the run-loop here by design — we are about to
    //     attach to it — so its inherited fd never closes during
    //     this cleanup, and the pump's POSIX read() never sees EOF.
    //     Joining would hang forever. Detach as in the orphan case;
    //     the pump exits naturally when the successor eventually
    //     closes its inherited fd (or zonvie exits first).
    //
    // For both detach paths we must call detachFromCore() BEFORE the
    // pump might dereference Core, since Core may be torn down while
    // the pump is still running. detachFromCore() takes the pump's
    // own mutex, waiting for any in-flight Core access to finish,
    // then nulls the pump's back-pointer to Core. Subsequent
    // iterations see core==null and skip every Core dereference.
    const detach_pump = orphan_child or self.restart_pending_addr != null;
    if (detach_pump) {
        // Drop our ref so the pump destroys itself when its thread
        // releases its ref. detachFromCore first under the pump's
        // mutex so the running pump stops dereferencing Core; then
        // release() drops Core's ref. Both calls require a live ref,
        // which we hold until the matched release().
        self.log.write("cleanupSession: stderr pump path=detach (orphan={any} restart_pending={any})\n", .{
            orphan_child,
            self.restart_pending_addr != null,
        });
        if (self.stderr_pump) |p| {
            p.detachFromCore();
            p.release();
            self.stderr_pump = null;
        }
        if (self.stderr_thread) |t| {
            t.detach();
            self.stderr_thread = null;
        }
        self.log.write("cleanupSession: stderr pump detached\n", .{});
    } else {
        // Final-shutdown path: child died, stderr writer closed,
        // pump thread observed EOF and exited (releasing its ref).
        // join() guarantees the thread has finished its release;
        // we then drop Core's ref to free the struct.
        self.log.write("cleanupSession: stderr pump path=join (thread_present={any} pump_present={any})\n", .{
            self.stderr_thread != null,
            self.stderr_pump != null,
        });
        if (self.stderr_thread) |t| {
            t.join();
            self.stderr_thread = null;
            self.log.write("cleanupSession: stderr thread joined\n", .{});
        }
        if (self.stderr_pump) |p| {
            p.release();
            self.stderr_pump = null;
            self.log.write("cleanupSession: stderr pump released\n", .{});
        }
    }

    // All threads that could dereference the Windows named-pipe wrapper
    // (writer thread, stderr pump, the run-loop reader inlined above)
    // have now been joined — safe to release the kernel HANDLEs and
    // free the heap allocation. Stream.close() above only canceled
    // pending I/O via CancelIoEx; the pipe HANDLE and the event
    // HANDLEs stayed alive until now so that threads sleeping in
    // GetOverlappedResult could wake up and exit cleanly without
    // their HANDLE references being yanked from under them. destroy()
    // closes those HANDLEs and frees the wrapper struct.
    if (self.session_pipe) |p| {
        self.log.write("cleanupSession: destroying session_pipe (Windows named pipe wrapper)\n", .{});
        p.destroy();
        self.session_pipe = null;
    }

    self.log.write("cleanupSession: returning (term_present={any})\n", .{session_term != null});
    return session_term;
}

test "redraw recovery retry limit is session fatal" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.redraw_recovery_attempts = max_redraw_recovery_attempts;

    beginRedrawRecovery(&core);

    try std.testing.expect(core.redraw_recovery_failed.load(.seq_cst));
    try std.testing.expectEqual(nvim_core.RedrawRecoveryState.healthy, core.redraw_recovery_state);
}

test "RPC stream hard limits poison the session" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    handleRpcStreamFailure(&core, error.MessageTooLarge);
    try std.testing.expect(core.redraw_recovery_failed.load(.seq_cst));
    try std.testing.expect(!core.ui_attached.load(.seq_cst));

    core.redraw_recovery_failed.store(false, .seq_cst);
    core.ui_attached.store(true, .seq_cst);
    handleRpcStreamFailure(&core, error.FrameTooLarge);
    try std.testing.expect(core.redraw_recovery_failed.load(.seq_cst));
    try std.testing.expect(!core.ui_attached.load(.seq_cst));
}

test "pre-flush grid 2 fallback is present in the same committed vertices" {
    const State = struct {
        saw_grid_2: bool = false,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = row_start;
            _ = row_count;
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 1 or flags & c_api.VERT_UPDATE_MAIN == 0 or verts == null) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            for (verts.?[0..vert_count]) |vertex| {
                if (vertex.grid_id == 2) self.saw_grid_2 = true;
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 1);
    try core.grid.resizeGrid(2, 1, 1);
    core.grid.putCellGrid(2, 0, 0, 'X', 0);
    core.grid.cursor_visible = false;
    core.drawable_w_px = 1;
    core.drawable_h_px = 1;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;

    var flush_ctx = flush.FlushCtx{ .core = &core };
    try prepareRenderStateForFlush(&flush_ctx);
    try std.testing.expect(core.grid.win_pos.contains(2));
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(state.saw_grid_2);
}

test "pre-flush glow resolution affects the same committed vertices" {
    const State = struct {
        saw_glow: bool = false,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = row_start;
            _ = row_count;
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 1 or flags & c_api.VERT_UPDATE_MAIN == 0 or verts == null) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            for (verts.?[0..vert_count]) |vertex| {
                if (vertex.deco_flags & c_api.DECO_GLOW != 0) self.saw_glow = true;
            }
        }

        fn rasterize(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = style_flags;
            out_bitmap.* = .{
                .pixels = null,
                .width = 1,
                .height = 1,
                .pitch = 1,
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = ctx;
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
        }

        fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
            _ = ctx;
            _ = atlas_w;
            _ = atlas_h;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 1);
    core.grid.putCell(0, 0, 'G', 42);
    core.grid.cursor_visible = false;
    core.drawable_w_px = 1;
    core.drawable_h_px = 1;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    const group_name = try core.alloc.dupe(u8, "GlowNow");
    core.glow_group_names.append(core.alloc, group_name) catch |err| {
        core.alloc.free(group_name);
        return err;
    };
    try core.hl.setGroup("GlowNow", 42);
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var flush_ctx = flush.FlushCtx{ .core = &core };
    try prepareRenderStateForFlush(&flush_ctx);
    try std.testing.expect(core.glow_enabled.load(.acquire));
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(state.saw_glow);
}

test "child reaper does not wait for inherited stderr EOF" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    clock.init();

    const reaper = try std.testing.allocator.create(ChildReaper);
    reaper.* = .{
        .alloc = std.testing.allocator,
        .mu = .init,
        .decision_ready = .init,
        .decided = false,
        .child = null,
        .refcount = std.atomic.Value(u32).init(2),
        .reaped = std.atomic.Value(bool).init(false),
    };
    const reaper_thread = try std.Thread.spawn(.{}, ChildReaper.run, .{reaper});
    var reaper_joined = false;
    defer {
        if (!reaper_joined) {
            reaper.finishWithoutChild();
            reaper_thread.join();
        }
        reaper.release();
    }

    var child = try std.process.spawn(clock.io(), .{
        .argv = &.{ "/bin/sh", "-c", "(trap '' HUP; sleep 1) & exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    const stderr_file = child.stderr.?;
    child.stderr = null;
    defer stderr_file.close(clock.io());

    try std.testing.expect(reaper.adopt(child));
    var waits: usize = 0;
    while (!reaper.reaped.load(.acquire) and waits < 500) : (waits += 1) {
        std.Io.sleep(clock.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expect(reaper.reaped.load(.acquire));

    // The background descendant still owns stderr's write end. A nonblocking
    // read must report WouldBlock rather than EOF even though the direct child
    // has already been waited and reaped.
    const stderr_stream = try rpc_transport.Stream.fromFile(stderr_file).preparePipeWriter();
    var byte: [1]u8 = undefined;
    const stderr_open = if (stderr_stream.read(&byte)) |n|
        n != 0
    else |e| switch (e) {
        error.WouldBlock => true,
        else => return e,
    };
    try std.testing.expect(stderr_open);

    reaper_thread.join();
    reaper_joined = true;
}

/// Drives the real handleClipboardSet over a real writer thread and pipe, so
/// both the bytes handed to the frontend and the RPC response Neovim receives
/// are observed rather than inferred.
const ClipboardSetProbe = struct {
    captured: std.ArrayListUnmanaged(u8) = .empty,
    calls: usize = 0,

    fn onSet(
        ctx: ?*anyopaque,
        register: [*]const u8,
        data: [*]const u8,
        len: usize,
    ) callconv(.c) c_int {
        _ = register;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.captured.appendSlice(std.testing.allocator, data[0..len]) catch @panic("oom");
        return 1;
    }

    fn run(self: *@This(), lines: []const []const u8) !bool {
        const alloc = std.testing.allocator;
        clock.init();

        var fds: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        const read_file = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };

        var core = Core.initForTest(alloc);
        core.ctx = self;
        core.stdin_file = rpc_transport.Stream.fromFile(
            .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        );
        core.transport_kind = .pipes;
        core.cb.on_clipboard_set = onSet;
        try std.testing.expect(core.startWriterThread());

        const vals = try alloc.alloc(mp.Value, lines.len);
        defer alloc.free(vals);
        for (lines, 0..) |l, i| vals[i] = .{ .str = l };
        var top = [2]mp.Value{ .{ .str = "+" }, .{ .arr = vals } };

        handleClipboardSet(&core, 7, .{ .arr = &top });

        // Response frame is [1, msgid, err, result].
        var rbuf: [256]u8 = undefined;
        const n = try rpc_transport.Stream.fromFile(read_file).read(&rbuf);
        var reader = mp.SliceReader{ .data = rbuf[0..n] };
        const decoded = try mp.decode(alloc, &reader);
        defer mp.freeValue(alloc, decoded);

        try std.testing.expectEqual(@as(usize, 1), self.calls);
        try std.testing.expect(decoded == .arr);

        core.stop();
        read_file.close(clock.io());
        // deinitForTest is intentionally omitted: iterating a never-populated
        // std HashMap asserts on Zig 0.16, which is why the sibling
        // writer-thread tests omit it too.

        return decoded.arr[3] == .bool and decoded.arr[3].bool;
    }

    /// What the register should contain: every line, '\n' between them.
    fn expected(alloc: std.mem.Allocator, lines: []const []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(alloc);
        for (lines, 0..) |l, i| {
            try out.appendSlice(alloc, l);
            if (i < lines.len - 1) try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }
};

test "clipboard set delivers every line when the register exceeds the staging buffer" {
    const alloc = std.testing.allocator;

    // 62 x 1000B fills most of the old 64 KiB staging buffer; the 4096B line
    // then cannot fit, and five short lines follow it. Without a heap buffer
    // the oversized line is dropped and the tails are still appended, so the
    // register loses its middle with no visible seam.
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (lines.items) |l| alloc.free(l);
        lines.deinit(alloc);
    }
    for (0..62) |_| {
        const l = try alloc.alloc(u8, 1000);
        @memset(l, 'a');
        try lines.append(alloc, l);
    }
    const big = try alloc.alloc(u8, 4096);
    @memset(big, 'b');
    try lines.append(alloc, big);
    for (0..5) |i| {
        const l = try alloc.alloc(u8, 5);
        @memset(l, @intCast('0' + i));
        try lines.append(alloc, l);
    }

    var probe = ClipboardSetProbe{};
    defer probe.captured.deinit(alloc);
    const ok = try probe.run(lines.items);

    const want = try ClipboardSetProbe.expected(alloc, lines.items);
    defer alloc.free(want);

    try std.testing.expect(ok);
    try std.testing.expectEqual(want.len, probe.captured.items.len);
    try std.testing.expectEqualSlices(u8, want, probe.captured.items);
}

test "clipboard set delivers a single line larger than the staging buffer" {
    const alloc = std.testing.allocator;

    // A minified file or a base64 blob is one very long line. Without a heap
    // buffer nothing fits, the frontend is handed zero bytes, and the RPC
    // response still reports success — the register silently becomes empty.
    const line = try alloc.alloc(u8, 100_000);
    defer alloc.free(line);
    @memset(line, 'z');
    const lines = [_][]const u8{line};

    var probe = ClipboardSetProbe{};
    defer probe.captured.deinit(alloc);
    const ok = try probe.run(&lines);

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 100_000), probe.captured.items.len);
    try std.testing.expectEqualSlices(u8, line, probe.captured.items);
}

/// Frontend stand-in that honours the on_clipboard_get contract: it reports
/// the total size and writes only what fits, so the core's retry loop is what
/// is actually under test.
const ClipboardGetProbe = struct {
    content: []const u8 = "",
    calls: usize = 0,
    saw_short_buffer: bool = false,

    fn onGet(
        ctx: ?*anyopaque,
        register: [*]const u8,
        out_buf: [*]u8,
        out_len: *usize,
        max_len: usize,
    ) callconv(.c) c_int {
        _ = register;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.content.len > max_len) self.saw_short_buffer = true;
        const n = @min(self.content.len, max_len);
        if (n > 0) @memcpy(out_buf[0..n], self.content[0..n]);
        out_len.* = self.content.len;
        return 1;
    }

    /// Returns the register content Neovim would receive, rejoined with '\n'.
    fn run(self: *@This(), alloc: std.mem.Allocator) ![]u8 {
        return fetchClipboard(alloc, self, onGet);
    }
};

test "clipboard get retries until the whole register fits" {
    const alloc = std.testing.allocator;

    // Larger than the core's stack staging buffer, so the first call reports a
    // short write and the core must allocate and fetch again.
    const content = try alloc.alloc(u8, 200_000);
    defer alloc.free(content);
    for (content, 0..) |*b, i| b.* = if (i % 97 == 0) '\n' else 'x';

    var probe = ClipboardGetProbe{ .content = content };
    const got = try probe.run(alloc);
    defer alloc.free(got);

    try std.testing.expect(probe.saw_short_buffer);
    try std.testing.expect(probe.calls >= 2);
    try std.testing.expectEqual(content.len, got.len);
    try std.testing.expectEqualSlices(u8, content, got);
}

test "clipboard get takes no heap path when the register already fits" {
    const alloc = std.testing.allocator;

    const content = "small clipboard\nsecond line";
    var probe = ClipboardGetProbe{ .content = content };
    const got = try probe.run(alloc);
    defer alloc.free(got);

    try std.testing.expect(!probe.saw_short_buffer);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqualSlices(u8, content, got);
}

/// Runs handleClipboardGet against the given frontend callback and returns the
/// register content Neovim would receive, rejoined with '\n'. Caller frees.
fn fetchClipboard(
    alloc: std.mem.Allocator,
    ctx: *anyopaque,
    get_cb: @TypeOf(ClipboardGetProbe.onGet),
) ![]u8 {
    clock.init();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    const read_file = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };

    var core = Core.initForTest(alloc);
    core.ctx = ctx;
    core.stdin_file = rpc_transport.Stream.fromFile(
        .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    );
    core.transport_kind = .pipes;
    core.cb.on_clipboard_get = get_cb;
    try std.testing.expect(core.startWriterThread());

    var top = [1]mp.Value{.{ .str = "+" }};
    handleClipboardGet(&core, 11, .{ .arr = &top });

    // The response can exceed one pipe read, so accumulate until a whole frame
    // decodes. A partial frame leaves the decoder's sub-allocations orphaned,
    // so each attempt gets an arena that is simply reset — the same reason the
    // production read loop uses one.
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(alloc);
    const stream = rpc_transport.Stream.fromFile(read_file);
    var chunk: [16 * 1024]u8 = undefined;
    var joined: []u8 = &.{};
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        try raw.appendSlice(alloc, chunk[0..n]);

        _ = arena_state.reset(.retain_capacity);
        var reader = mp.SliceReader{ .data = raw.items };
        const decoded = mp.decode(arena_state.allocator(), &reader) catch |e| switch (e) {
            error.EndOfStream => continue,
            else => return e,
        };

        // [1, msgid, err, [[lines...], regtype]]
        try std.testing.expect(decoded == .arr);
        try std.testing.expect(decoded.arr[2] == .nil);
        const lines = decoded.arr[3].arr[0].arr;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(alloc);
        for (lines, 0..) |l, i| {
            try out.appendSlice(alloc, l.str);
            if (i < lines.len - 1) try out.append(alloc, '\n');
        }
        joined = try out.toOwnedSlice(alloc);
        break;
    }

    core.stop();
    read_file.close(clock.io());
    return joined;
}

/// Stands in for the system pasteboard: whatever the copy path writes is what
/// the paste path later reports, honouring the full-size contract.
const ClipboardBoard = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn onSet(
        ctx: ?*anyopaque,
        register: [*]const u8,
        data: [*]const u8,
        len: usize,
    ) callconv(.c) c_int {
        _ = register;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSlice(std.testing.allocator, data[0..len]) catch @panic("oom");
        return 1;
    }

    fn onGet(
        ctx: ?*anyopaque,
        register: [*]const u8,
        out_buf: [*]u8,
        out_len: *usize,
        max_len: usize,
    ) callconv(.c) c_int {
        _ = register;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const n = @min(self.bytes.items.len, max_len);
        if (n > 0) @memcpy(out_buf[0..n], self.bytes.items[0..n]);
        out_len.* = self.bytes.items.len;
        return 1;
    }
};

test "yank and put round-trip a register larger than the staging buffers" {
    const alloc = std.testing.allocator;

    // Both directions used a 64 KiB staging buffer, so a register above that
    // lost content on the way out and again on the way back. This is the whole
    // user-visible operation: "+y a big selection, then "+p it.
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (lines.items) |l| alloc.free(l);
        lines.deinit(alloc);
    }
    for (0..300) |i| {
        const l = try alloc.alloc(u8, 400);
        @memset(l, @intCast('a' + (i % 26)));
        try lines.append(alloc, l);
    }

    var board = ClipboardBoard{};
    defer board.bytes.deinit(alloc);

    // Copy.
    {
        clock.init();

        var fds: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        const read_file = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };

        var core = Core.initForTest(alloc);
        core.ctx = &board;
        core.stdin_file = rpc_transport.Stream.fromFile(
            .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        );
        core.transport_kind = .pipes;
        core.cb.on_clipboard_set = ClipboardBoard.onSet;
        try std.testing.expect(core.startWriterThread());

        const vals = try alloc.alloc(mp.Value, lines.items.len);
        defer alloc.free(vals);
        for (lines.items, 0..) |l, i| vals[i] = .{ .str = l };
        var top = [2]mp.Value{ .{ .str = "+" }, .{ .arr = vals } };
        handleClipboardSet(&core, 7, .{ .arr = &top });

        core.stop();
        read_file.close(clock.io());
    }

    // Paste.
    const pasted = try fetchClipboard(alloc, &board, ClipboardBoard.onGet);
    defer alloc.free(pasted);

    const want = try ClipboardSetProbe.expected(alloc, lines.items);
    defer alloc.free(want);

    try std.testing.expect(want.len > 64 * 1024);
    try std.testing.expectEqual(want.len, board.bytes.items.len);
    try std.testing.expectEqual(want.len, pasted.len);
    try std.testing.expectEqualSlices(u8, want, pasted);
}
