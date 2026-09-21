// Platform-independent tests for the wheel's grid resolution. The production
// caller passes `app.SurfaceLayer` and `app.GridInfo`; these declare their own
// structs with the fields the rule reads, which is what keeps the rule
// testable without Win32.

const std = @import("std");
const wheel_target = @import("wheel_target.zig");

const Layer = struct {
    grid_id: i64,
    x_px: i32,
    y_px: i32,
    rows: u32,
    cols: u32,
    mouse_enabled: bool = true,
};

const Grid = struct {
    grid_id: i64,
    rows: i32,
    margin_top: i32 = 0,
    margin_bottom: i32 = 0,
    line_count: i64,
};

const cell_w: u32 = 10;
const row_h: u32 = 20;

/// A surface whose root is grid 2, with one float over it. The float covers
/// x 100..400, y 200..400.
fn oneFloat(mouse_enabled: bool) [2]Layer {
    return .{
        .{ .grid_id = 2, .x_px = 0, .y_px = 0, .rows = 40, .cols = 80 },
        .{ .grid_id = 5, .x_px = 100, .y_px = 200, .rows = 10, .cols = 30, .mouse_enabled = mouse_enabled },
    };
}

test "a point inside a scrollable float names it, in its own pixels" {
    const layers = oneFloat(true);
    const hit = wheel_target.resolve(Layer, &layers, 2, 150, 250, cell_w, row_h, &.{5});
    try std.testing.expectEqual(@as(i64, 5), hit.grid_id);
    try std.testing.expectEqual(@as(i32, 50), hit.x_px);
    try std.testing.expectEqual(@as(i32, 50), hit.y_px);
}

test "a point outside every float stays with the surface root" {
    const layers = oneFloat(true);
    const hit = wheel_target.resolve(Layer, &layers, 2, 50, 50, cell_w, row_h, &.{5});
    try std.testing.expectEqual(@as(i64, 2), hit.grid_id);
    try std.testing.expectEqual(@as(i32, 50), hit.x_px);
    try std.testing.expectEqual(@as(i32, 50), hit.y_px);
}

test "a float that refuses the mouse does not take the event, nor shadow what is under it" {
    // Neovim rejects an event addressed to such a window without re-resolving,
    // so naming it would swallow the scroll.
    const layers = oneFloat(false);
    const hit = wheel_target.resolve(Layer, &layers, 2, 150, 250, cell_w, row_h, &.{5});
    try std.testing.expectEqual(@as(i64, 2), hit.grid_id);
}

test "a float showing all of its content lets the scroll through" {
    const layers = oneFloat(true);
    const hit = wheel_target.resolve(Layer, &layers, 2, 150, 250, cell_w, row_h, &.{});
    try std.testing.expectEqual(@as(i64, 2), hit.grid_id);
}

test "a scrollable float under a non-scrollable one still takes the event" {
    const layers = [_]Layer{
        .{ .grid_id = 2, .x_px = 0, .y_px = 0, .rows = 40, .cols = 80 },
        .{ .grid_id = 5, .x_px = 100, .y_px = 200, .rows = 10, .cols = 30 },
        .{ .grid_id = 6, .x_px = 100, .y_px = 200, .rows = 10, .cols = 30 },
    };
    // 6 is drawn over 5 but shows all of its content; 5 is the one that scrolls.
    const hit = wheel_target.resolve(Layer, &layers, 2, 150, 250, cell_w, row_h, &.{5});
    try std.testing.expectEqual(@as(i64, 5), hit.grid_id);
}

test "the later of two overlapping floats wins, because that is the one drawn on top" {
    const layers = [_]Layer{
        .{ .grid_id = 2, .x_px = 0, .y_px = 0, .rows = 40, .cols = 80 },
        .{ .grid_id = 5, .x_px = 100, .y_px = 200, .rows = 10, .cols = 30 },
        .{ .grid_id = 6, .x_px = 100, .y_px = 200, .rows = 10, .cols = 30 },
    };
    const hit = wheel_target.resolve(Layer, &layers, 2, 150, 250, cell_w, row_h, &.{ 5, 6 });
    try std.testing.expectEqual(@as(i64, 6), hit.grid_id);
}

test "a grid no layer of this surface places is not reachable at all" {
    // The rule the main window lost by hit-testing the grid list: a float an
    // EXTERNAL window hosts reports its position in that surface's space, and
    // is absent from this surface's layers. Naming it from here put the scroll
    // in another window.
    const layers = oneFloat(true);
    const hit = wheel_target.resolve(Layer, &layers, 2, 150, 250, cell_w, row_h, &.{ 5, 9 });
    try std.testing.expect(hit.grid_id != 9);
}

test "the surface's own root is never a candidate" {
    // layers[0] is the root; a point on it must keep the caller's grid id and
    // the unshifted point, not be rebased against layers[0]'s origin.
    const layers = [_]Layer{
        .{ .grid_id = 2, .x_px = 30, .y_px = 40, .rows = 40, .cols = 80 },
    };
    const hit = wheel_target.resolve(Layer, &layers, 2, 150, 250, cell_w, row_h, &.{2});
    try std.testing.expectEqual(@as(i64, 2), hit.grid_id);
    try std.testing.expectEqual(@as(i32, 150), hit.x_px);
    try std.testing.expectEqual(@as(i32, 250), hit.y_px);
}

test "a zero cell size cannot name a layer" {
    const layers = oneFloat(true);
    const hit = wheel_target.resolve(Layer, &layers, 2, 150, 250, 0, row_h, &.{5});
    try std.testing.expectEqual(@as(i64, 2), hit.grid_id);
}

test "scrollable grids are the ones with more lines than their content area shows" {
    const grids = [_]Grid{
        .{ .grid_id = 2, .rows = 40, .line_count = 400 },
        .{ .grid_id = 5, .rows = 10, .line_count = 10 }, // fits exactly
        .{ .grid_id = 6, .rows = 10, .line_count = 11 },
        // A bordered float: two of its rows are margin, so eight show content.
        .{ .grid_id = 7, .rows = 10, .margin_top = 1, .margin_bottom = 1, .line_count = 9 },
    };
    var buf: [8]i64 = undefined;
    const ids = wheel_target.collectScrollableGridIds(Grid, &grids, &buf);
    try std.testing.expectEqualSlices(i64, &.{ 2, 6, 7 }, ids);
}

test "collecting scrollable grids never writes past the caller's buffer" {
    const grids = [_]Grid{
        .{ .grid_id = 1, .rows = 1, .line_count = 99 },
        .{ .grid_id = 2, .rows = 1, .line_count = 99 },
        .{ .grid_id = 3, .rows = 1, .line_count = 99 },
    };
    var buf: [2]i64 = undefined;
    const ids = wheel_target.collectScrollableGridIds(Grid, &grids, &buf);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, ids);
}
