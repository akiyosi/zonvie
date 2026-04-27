const std = @import("std");

pub const Logger = struct {
    cb: ?*const fn (ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void = null,
    ctx: ?*anyopaque = null,
    /// Per-cell / per-glyph hot-path debug logs (e.g. [shape_dump], [glyph_quad]).
    /// Off by default: enabling them produces thousands of lines per second on
    /// active editing, which dominates RSS measurement noise via Foundation
    /// allocation churn. Toggle to true only for targeted shaping/atlas debug.
    verbose: bool = false,

    pub fn write(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        if (self.cb == null) return;

        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.cb.?(self.ctx, msg.ptr, msg.len);
    }
};
