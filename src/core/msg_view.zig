//! Message view lifecycle, modelled on noice.nvim's `NoiceView`
//! (`view/init.lua`).
//!
//! noice assigns messages to a view with `push`, then `display()` decides
//! between `show()` and `hide()` from whether the view holds anything
//! (`view/init.lua:156-180`). Zonvie previously had no such object: each view
//! kind was handled by an ad-hoc arm of four separate `switch` statements, and
//! the same messages were routed four times per cycle — once inconsistently,
//! with a different line count, which could silently drop a message from the
//! rendered grid.
//!
//! This holds the per-cycle assignment and the visibility bookkeeping. The
//! backends stay in flush.zig, because they need Core; everything here is pure
//! state so it can be tested on its own.
//!
//! Not modelled: noice's tick/diff update (`message/router.lua:172-208`), which
//! needs per-message identity Zonvie does not have. Zonvie rebuilds the
//! assignment from scratch every cycle instead.

const std = @import("std");
const msg_route = @import("msg_route.zig");

pub const MsgViewType = msg_route.MsgViewType;

pub const view_count = @typeInfo(MsgViewType).@"enum".fields.len;

/// Who owns hiding a view once it has been shown.
pub const Retention = enum {
    /// The core drives both show and hide.
    retained,
    /// Display ownership transfers on show — a frontend timer, the OS
    /// notification centre, or Neovim itself takes over. The core must not
    /// keep the message around waiting to hide it.
    transient,
};

pub fn retentionOf(view: MsgViewType) Retention {
    return switch (view) {
        // Rendered into the core's own external grid, so the core hides it.
        .ext_float => .retained,
        // `mini` hides on the frontend's timer, `notification` belongs to the
        // OS, `split` to Neovim, `confirm` to the prompt flow, and `none` was
        // never shown.
        .mini, .confirm, .notification, .split, .none => .transient,
    };
}

/// What the caller must do for a view this cycle.
pub const Action = enum { none, show, hide };

pub const ViewState = struct {
    visible: bool = false,
    /// Messages assigned to this view in the current cycle.
    count: u32 = 0,
    /// Largest timeout among the assigned messages, in seconds. 0 = no auto-hide.
    timeout: f32 = 0,
};

pub const ViewSet = struct {
    states: [view_count]ViewState = [_]ViewState{.{}} ** view_count,
    /// Per-message view assignment for the current cycle, parallel to the
    /// caller's message array. Persistent so capacity is reused.
    assigned: std.ArrayListUnmanaged(MsgViewType) = .empty,

    pub fn deinit(self: *ViewSet, alloc: std.mem.Allocator) void {
        self.assigned.deinit(alloc);
        self.assigned = .empty;
    }

    /// Start a cycle for `message_count` messages. Visibility is preserved;
    /// only the per-cycle assignment is reset.
    pub fn beginCycle(self: *ViewSet, alloc: std.mem.Allocator, message_count: usize) !void {
        for (&self.states) |*s| {
            s.count = 0;
            s.timeout = 0;
        }
        self.assigned.clearRetainingCapacity();
        try self.assigned.ensureTotalCapacity(alloc, message_count);
        self.assigned.appendNTimesAssumeCapacity(.none, message_count);
    }

    /// Assign message `index` to `view`. Out-of-range indices are ignored so a
    /// caller that grew its message list mid-cycle cannot corrupt state.
    pub fn assign(self: *ViewSet, index: usize, view: MsgViewType, timeout: f32) void {
        if (index >= self.assigned.items.len) return;
        self.assigned.items[index] = view;
        const s = &self.states[@intFromEnum(view)];
        s.count += 1;
        if (timeout > s.timeout) s.timeout = timeout;
    }

    pub fn assignedTo(self: *const ViewSet, index: usize) MsgViewType {
        if (index >= self.assigned.items.len) return .none;
        return self.assigned.items[index];
    }

    pub fn state(self: *const ViewSet, view: MsgViewType) ViewState {
        return self.states[@intFromEnum(view)];
    }

    /// noice `View:display()`: something to show means show, nothing to show
    /// means hide — but only for views the core still owns.
    pub fn action(self: *const ViewSet, view: MsgViewType) Action {
        if (view == .none) return .none;
        const s = self.states[@intFromEnum(view)];
        if (s.count > 0) return .show;
        if (s.visible and retentionOf(view) == .retained) return .hide;
        return .none;
    }

    pub fn markShown(self: *ViewSet, view: MsgViewType) void {
        self.states[@intFromEnum(view)].visible = retentionOf(view) == .retained;
    }

    pub fn markHidden(self: *ViewSet, view: MsgViewType) void {
        self.states[@intFromEnum(view)].visible = false;
    }

    /// Views in dispatch order. `ext_float` runs first so a failed render
    /// aborts the flush before any transient view has been handed off.
    pub const dispatch_order = [_]MsgViewType{
        .ext_float,
        .split,
        .mini,
        .confirm,
        .notification,
    };
};
