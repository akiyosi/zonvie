const std = @import("std");

pub const Logger = struct {
    cb: ?*const fn (ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void = null,
    ctx: ?*anyopaque = null,
    /// Per-cell / per-glyph hot-path debug logs (e.g. [shape_dump], [glyph_quad]).
    /// Off by default: enabling them produces thousands of lines per second on
    /// active editing, which dominates RSS measurement noise via Foundation
    /// allocation churn. Toggle to true only for targeted shaping/atlas debug.
    verbose: bool = false,
    /// When true, only messages whose format string starts with "[perf]" or
    /// "[perf_" are emitted (e.g. [perf_input]). Lets users enable timing
    /// logs without the noise of debug logs like [scroll_debug], [cmdline],
    /// [msg], etc. Independent of `verbose` (which gates the
    /// highest-frequency [shape_dump] / [glyph_quad] lines).
    perf_only: bool = false,
    /// Scroll-pipeline analysis mode: like `perf_only` but additionally lets
    /// [scroll_debug] lines through, so the input -> grid_scroll -> flush ->
    /// commit -> draw chain can be traced without the rest of the debug
    /// noise. Takes precedence over `perf_only` when both are set.
    scroll_only: bool = false,

    pub fn write(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        if (self.cb == null) return;
        // Match the closed forms only ("[perf]" / "[perf_xxx]") so a future
        // unrelated tag like "[performance_audit]" doesn't accidentally pass
        // the perf-only filter.
        const is_perf = comptime (std.mem.startsWith(u8, fmt, "[perf]") or
            std.mem.startsWith(u8, fmt, "[perf_"));
        const is_scroll = comptime std.mem.startsWith(u8, fmt, "[scroll_debug]");
        if (self.scroll_only) {
            if (!is_perf and !is_scroll) return;
        } else if (self.perf_only and !is_perf) return;

        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.cb.?(self.ctx, msg.ptr, msg.len);
    }

    /// True when callers should pay the cost of building a [perf] line.
    /// Equivalent to `cb != null` because perf lines are always allowed
    /// when logging is on; `perf_only` only filters non-perf lines.
    pub inline fn perfEnabled(self: *const Logger) bool {
        return self.cb != null;
    }
};
