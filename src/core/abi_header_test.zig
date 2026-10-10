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

/// A field's type class, so two fields of equal size and offset still differ
/// when one is a float and the other an integer, or an unsigned integer and a
/// signed one. Arrays are classified by their element; optional pointers
/// (Zig's spelling of a nullable C pointer) as pointers. Ints encode
/// signedness and bit width. An enum is an unsigned int of its tag's width:
/// a C enum's signedness is implementation-defined (clang lowers one with
/// non-negative values to unsigned), so only the width is a contract.
fn typeKind(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .array => |a| typeKind(a.child),
        .@"enum" => |e| 1000 + @typeInfo(e.tag_type).int.bits,
        .optional => |o| typeKind(o.child),
        .int => |i| 1000 + @as(usize, if (i.signedness == .signed) 1 else 0) * 256 + i.bits,
        .float => 2000,
        .bool => 3000,
        .pointer => 4000,
        .@"struct" => 5000,
        else => @compileError("unclassified ABI field type " ++ @typeName(T)),
    };
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
        expectEq(what ++ " type kind", typeKind(a.type), typeKind(b.type), failures);
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

/// Every header #define / anonymous-enum value that has a Zig twin, and the
/// values of the C enums the core receives raw. A new header constant is one
/// more row.
const constant_pairs = .{
    .{ c.ZONVIE_STYLE_BOLD, c_api.STYLE_BOLD },
    .{ c.ZONVIE_STYLE_ITALIC, c_api.STYLE_ITALIC },
    .{ c.ZONVIE_DECO_UNDERCURL, c_api.DECO_UNDERCURL },
    .{ c.ZONVIE_DECO_UNDERLINE, c_api.DECO_UNDERLINE },
    .{ c.ZONVIE_DECO_UNDERDOUBLE, c_api.DECO_UNDERDOUBLE },
    .{ c.ZONVIE_DECO_UNDERDOTTED, c_api.DECO_UNDERDOTTED },
    .{ c.ZONVIE_DECO_UNDERDASHED, c_api.DECO_UNDERDASHED },
    .{ c.ZONVIE_DECO_STRIKETHROUGH, c_api.DECO_STRIKETHROUGH },
    .{ c.ZONVIE_DECO_CURSOR, c_api.DECO_CURSOR },
    .{ c.ZONVIE_DECO_SCROLLABLE, c_api.DECO_SCROLLABLE },
    .{ c.ZONVIE_DECO_OVERLINE, c_api.DECO_OVERLINE },
    .{ c.ZONVIE_DECO_GLOW, c_api.DECO_GLOW },
    .{ c.ZONVIE_DECO_COLOR_EMOJI, c_api.DECO_COLOR_EMOJI },
    .{ c.ZONVIE_DECO_SOLID_GLYPH, c_api.DECO_SOLID_GLYPH },
    .{ c.ZONVIE_VERT_UPDATE_MAIN, c_api.VERT_UPDATE_MAIN },
    .{ c.ZONVIE_VERT_UPDATE_CURSOR, c_api.VERT_UPDATE_CURSOR },
    .{ c.ZONVIE_MOD_CTRL, c_api.MOD_CTRL },
    .{ c.ZONVIE_MOD_ALT, c_api.MOD_ALT },
    .{ c.ZONVIE_MOD_SHIFT, c_api.MOD_SHIFT },
    .{ c.ZONVIE_MOD_SUPER, c_api.MOD_SUPER },
    .{ c.ZONVIE_LAYER_FOLLOWS_SCROLL, c_api.LAYER_FOLLOWS_SCROLL },
    .{ c.ZONVIE_LAYER_MOUSE_ENABLED, c_api.LAYER_MOUSE_ENABLED },
    .{ c.ZONVIE_LAYER_FLOAT, c_api.LAYER_FLOAT },
    .{ c.ZONVIE_GRID_ID_CMDLINE, c_api.grid_mod.CMDLINE_GRID_ID },
    .{ c.ZONVIE_GRID_ID_POPUPMENU, c_api.grid_mod.POPUPMENU_GRID_ID },
    .{ c.ZONVIE_GRID_ID_MESSAGE, c_api.grid_mod.MESSAGE_GRID_ID },
    .{ c.ZONVIE_GRID_ID_MSG_HISTORY, c_api.grid_mod.MSG_HISTORY_GRID_ID },
    .{ c.ZONVIE_MSG_VIEW_MINI, @intFromEnum(c_api.zonvie_msg_view_type.mini) },
    .{ c.ZONVIE_MSG_VIEW_EXT_FLOAT, @intFromEnum(c_api.zonvie_msg_view_type.ext_float) },
    .{ c.ZONVIE_MSG_VIEW_CONFIRM, @intFromEnum(c_api.zonvie_msg_view_type.confirm) },
    .{ c.ZONVIE_MSG_VIEW_SPLIT, @intFromEnum(c_api.zonvie_msg_view_type.split) },
    .{ c.ZONVIE_MSG_VIEW_NONE, @intFromEnum(c_api.zonvie_msg_view_type.none) },
    .{ c.ZONVIE_MSG_VIEW_NOTIFICATION, @intFromEnum(c_api.zonvie_msg_view_type.notification) },
    .{ c.ZONVIE_MSG_EVENT_MSG_SHOW, @intFromEnum(c_api.zonvie_msg_event.msg_show) },
    .{ c.ZONVIE_MSG_EVENT_MSG_SHOWMODE, @intFromEnum(c_api.zonvie_msg_event.msg_showmode) },
    .{ c.ZONVIE_MSG_EVENT_MSG_SHOWCMD, @intFromEnum(c_api.zonvie_msg_event.msg_showcmd) },
    .{ c.ZONVIE_MSG_EVENT_MSG_RULER, @intFromEnum(c_api.zonvie_msg_event.msg_ruler) },
    .{ c.ZONVIE_MSG_EVENT_MSG_HISTORY_SHOW, @intFromEnum(c_api.zonvie_msg_event.msg_history_show) },
    .{ c.ZONVIE_SHADER_TARGET_MSL, @intFromEnum(c_api.zonvie_shader_target.msl) },
    .{ c.ZONVIE_SHADER_TARGET_HLSL, @intFromEnum(c_api.zonvie_shader_target.hlsl) },
};

test "header constants match their c_api twins" {
    var failures: usize = 0;
    inline for (constant_pairs, 0..) |p, i| {
        const header: i64 = @intCast(p[0]);
        const zig: i64 = @intCast(p[1]);
        if (header != zig) {
            std.debug.print("ABI constant mismatch: row {d}: header {d}, zig {d}\n", .{ i, header, zig });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
