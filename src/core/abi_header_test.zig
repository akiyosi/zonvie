//! Checks every extern struct the core shares with frontends against its
//! declaration in include/zonvie_core.h or include/zonvie_frontend.h, as the
//! C compiler lays it out. Fields are matched by position, since several Zig
//! names differ from C.

const std = @import("std");
const c = @cImport({
    @cInclude("zonvie_core.h");
    @cInclude("zonvie_frontend.h");
});

const c_api = @import("c_api.zig");
const row_scroll = @import("row_scroll.zig");
const damage_bands = @import("damage_bands.zig");
const cursor_rect = @import("cursor_rect.zig");
const win_layout = @import("win_layout.zig");
const pointer_target = @import("pointer_target.zig");
const scrollbar_metrics = @import("scrollbar_metrics.zig");
const frontend_rules = @import("frontend_rules.zig");
const glow_chain = @import("glow_chain.zig");

const pairs = .{
    .{ c.zonvie_glyph_entry, c_api.GlyphEntry },
    .{ c.zonvie_glyph_bitmap, c_api.GlyphBitmap },
    .{ c.zonvie_vertex, c_api.Vertex },
    .{ c.zonvie_layer, c_api.Layer },
    .{ c.zonvie_cmdline_chunk, c_api.CmdlineChunk },
    .{ c.zonvie_cmdline_block_line, c_api.CmdlineBlockLine },
    .{ c.zonvie_msg_chunk, c_api.MsgChunk },
    .{ c.zonvie_msg_history_entry, c_api.MsgHistoryEntry },
    .{ c.zonvie_popupmenu_colors, c_api.PopupmenuColors },
    .{ c.zonvie_tab_entry, c_api.TabEntry },
    .{ c.zonvie_buffer_entry, c_api.BufferEntry },
    .{ c.zonvie_row_scroll_plan, row_scroll.Plan },
    .{ c.zonvie_damage_band, damage_bands.Band },
    .{ c.zonvie_over_blit_rows, c_api.OverBlitRowsC },
    .{ c.zonvie_row_scroll, row_scroll.Staged },
    .{ c.zonvie_row_scroll_merge, c_api.RowScrollMergeC },
    .{ c.zonvie_cursor_rect, cursor_rect.Rect },
    .{ c.zonvie_grid_info, c_api.GridInfo },
    .{ c.zonvie_msg_anchor, c_api.MsgAnchor },
    .{ c.zonvie_pointer_hit, pointer_target.Hit },
    .{ c.zonvie_scrollbar_metrics, scrollbar_metrics.Metrics },
    .{ c.zonvie_scrollbar_drag_target, scrollbar_metrics.DragTarget },
    .{ c.zonvie_win_frame, win_layout.Frame },
    .{ c.zonvie_press_claim, frontend_rules.PressClaim },
    .{ c.zonvie_saved_origin, frontend_rules.SavedOrigin },
    .{ c.zonvie_placement_memory, frontend_rules.PlacementMemory },
    .{ c.zonvie_blink, frontend_rules.Blink },
    .{ c.zonvie_viewport_info, c_api.ViewportInfo },
    .{ c.zonvie_glow_pass, glow_chain.Pass },
    .{ c.zonvie_glow_chain, glow_chain.Chain },
    .{ c.zonvie_route_result, c_api.zonvie_route_result },
    .{ c.zonvie_config_values, c_api.zonvie_config_values },
    .{ c.zonvie_shader_uniforms, c_api.zonvie_shader_uniforms },
    .{ c.zonvie_shader_result, c_api.zonvie_shader_result },
};

fn expectEq(what: []const u8, a: usize, b: usize, failures: *usize) void {
    if (a == b) return;
    std.debug.print("ABI mismatch: {s}: header {d}, zig {d}\n", .{ what, a, b });
    failures.* += 1;
}

fn fnInfo(comptime T: type) std.builtin.Type.Fn {
    const ptr = @typeInfo(@typeInfo(T).optional.child).pointer;
    return @typeInfo(ptr.child).@"fn";
}

fn isFloat(comptime T: type) usize {
    return @intFromBool(@typeInfo(T) == .float);
}

fn sizeOrZero(comptime T: type) usize {
    return if (T == void) 0 else @sizeOf(T);
}

fn checkStruct(comptime C: type, comptime Z: type, failures: *usize) void {
    const name = @typeName(Z);
    expectEq(name ++ " size", @sizeOf(C), @sizeOf(Z), failures);
    expectEq(name ++ " align", @alignOf(C), @alignOf(Z), failures);
    const cf = @typeInfo(C).@"struct".fields;
    const zf = @typeInfo(Z).@"struct".fields;
    expectEq(name ++ " field count", cf.len, zf.len, failures);
    inline for (cf[0..@min(cf.len, zf.len)], zf[0..@min(cf.len, zf.len)]) |a, b| {
        const what = name ++ "." ++ b.name;
        expectEq(what ++ " offset", @offsetOf(C, a.name), @offsetOf(Z, b.name), failures);
        expectEq(what ++ " size", @sizeOf(a.type), @sizeOf(b.type), failures);
    }
}

fn checkCallbacks(failures: *usize) void {
    const C = c.zonvie_callbacks;
    const Z = c_api.Callbacks;
    checkStruct(C, Z, failures);
    const cf = @typeInfo(C).@"struct".fields;
    const zf = @typeInfo(Z).@"struct".fields;
    if (cf.len != zf.len) return;
    // Field 0 is abi_version; every other field is a function pointer.
    inline for (cf[1..], zf[1..]) |a, b| {
        const what = "Callbacks." ++ b.name;
        const fa = fnInfo(a.type);
        const fb = fnInfo(b.type);
        expectEq(what ++ " param count", fa.params.len, fb.params.len, failures);
        if (fa.params.len == fb.params.len) {
            inline for (fa.params, fb.params, 0..) |pa, pb, i| {
                const pw = comptime blk: {
                    @setEvalBranchQuota(100000);
                    break :blk std.fmt.comptimePrint("{s} param {d}", .{ what, i });
                };
                expectEq(pw ++ " size", @sizeOf(pa.type.?), @sizeOf(pb.type.?), failures);
                expectEq(pw ++ " is float", isFloat(pa.type.?), isFloat(pb.type.?), failures);
            }
        }
        expectEq(what ++ " return size", sizeOrZero(fa.return_type.?), sizeOrZero(fb.return_type.?), failures);
    }
}

test "extern structs and callbacks match include/zonvie_core.h" {
    @setEvalBranchQuota(100000);
    var failures: usize = 0;
    inline for (pairs) |p| checkStruct(p[0], p[1], &failures);
    checkCallbacks(&failures);
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(@as(u32, c.ZONVIE_CALLBACKS_ABI_VERSION), c_api.CALLBACKS_ABI_VERSION);
}
