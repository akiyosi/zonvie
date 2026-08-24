//! Placement arithmetic for the ext_messages floats (msg_show / msg_history).
//!
//! Kept free of Win32 so it can be exercised on any host; the caller in
//! ui/external_windows.zig gathers the RECTs and applies the result.

const std = @import("std");

pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const Point = struct { x: i32, y: i32 };

/// Inset from the target rect's right and top edges.
pub const margin_px: i32 = 10;
/// Gap between msg_history and the msg_show float stacked below it.
pub const history_gap_px: i32 = 4;

/// Top-right placement.
///
/// The core registers these grids with start_row = start_col = -2, a sentinel
/// meaning "position at top-right" rather than literal cell coordinates, so x
/// is a function of the CURRENT window width and the target rect only. The
/// previous position is deliberately not an input: reusing it is exactly the
/// bug this replaced, where a short message inherited a long message's left
/// edge and pulled away from the right edge.
///
/// `history_bottom` is the msg_history float's bottom edge in screen
/// coordinates when msg_show must stack below it, and null otherwise (always
/// null for msg_history itself).
pub fn msgFloatTopRight(target: Rect, window_w: i32, history_bottom: ?i32) Point {
    return .{
        .x = target.right - window_w - margin_px,
        .y = if (history_bottom) |bottom| bottom + history_gap_px else target.top + margin_px,
    };
}
